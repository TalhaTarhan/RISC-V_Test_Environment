import os
import shutil
import subprocess
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

# ── Configuration ─────────────────────────────────────────────────────────────
RVGCCPREFIX = "riscv-none-elf-"
GHDLEXE     = "ghdl"
# Path to neorv32_top.vhd (your custom core), relative to THIS file's directory
CORE_VHD    = "neorv32_top.vhd"
# Path to rvtest_tb.vhd (testbench), relative to THIS file's directory
TB_VHD      = "rvtest_tb.vhd"
TESTBENCH   = "rvtest_tb"   # must match the entity name inside TB_VHD
MEM_SIZE    = 4 * 1024 * 1024   # bytes (4 MiB is plenty for arch-test)
TIMEOUT_CYC = 2000000           # testbench gives up after this many cycles
# ──────────────────────────────────────────────────────────────────────────────


def bin_to_hex(bin_file, hex_file):
    """Flat binary -> one little-endian 32-bit word per line (hex)."""
    with open(bin_file, "rb") as f:
        d = f.read()
    d += b"\0" * (-len(d) % 4)
    with open(hex_file, "w") as f:
        for i in range(0, len(d), 4):
            f.write("%08x\n" % int.from_bytes(d[i:i + 4], "little"))


class neorv32(pluginTemplate):
    __model__   = "neorv32"
    __version__ = "latest"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)

        config = kwargs.get('config')
        if config is None:
            print("Please enter input file paths in configuration.")
            raise SystemExit(1)

        self.num_jobs     = str(config.get('jobs', 1))
        self.pluginpath   = os.path.abspath(config['pluginpath'])
        self.isa_spec     = os.path.abspath(config['ispec'])
        self.platform_spec= os.path.abspath(config['pspec'])
        self.target_run   = config.get('target_run', '1') != '0'

        # Absolute paths to the two VHDL files (sit next to this .py file)
        self.core_vhd = os.path.join(self.pluginpath, CORE_VHD)
        self.tb_vhd   = os.path.join(self.pluginpath, TB_VHD)

        # Analyse + elaborate once at startup into a local work directory
        self.ghdl_work = os.path.join(self.pluginpath, "ghdl_work")
        os.makedirs(self.ghdl_work, exist_ok=True)

        logger.debug("DUT: analysing VHDL sources ...")

        # Analyse core
        cmd = (f"{GHDLEXE} -a --std=08 -frelaxed "
               f"--workdir={self.ghdl_work} {self.core_vhd}")
        logger.debug("DUT: " + cmd)
        utils.shellCommand(cmd).run()

        # Analyse testbench
        cmd = (f"{GHDLEXE} -a --std=08 -frelaxed "
               f"--workdir={self.ghdl_work} {self.tb_vhd}")
        logger.debug("DUT: " + cmd)
        utils.shellCommand(cmd).run()

        # Elaborate
        cmd = (f"{GHDLEXE} -e --std=08 -frelaxed "
               f"--workdir={self.ghdl_work} {TESTBENCH}")
        logger.debug("DUT: " + cmd)
        utils.shellCommand(cmd).run()

        return sclass

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir  = work_dir
        self.suite_dir = suite

        self.compile_cmd = (
            f"{RVGCCPREFIX}gcc"
            " -march={{0}}"
            " -static -mcmodel=medany -fvisibility=hidden"
            " -nostdlib -nostartfiles -g"
            f" -T {self.pluginpath}/env/link.ld"
            f" -I {self.pluginpath}/env/"
            " -I {archtest_env}"
            " {{2}} -o {{3}} {{4}}"
        ).format(archtest_env=archtest_env)

        # Simpler: build the compile string with positional placeholders
        self.compile_cmd = (
            f"{RVGCCPREFIX}gcc"
            " -march={0}"
            " -static -mcmodel=medany -fvisibility=hidden"
            " -nostdlib -nostartfiles -g"
            f" -T {self.pluginpath}/env/link.ld"
            f" -I {self.pluginpath}/env/"
            f" -I {archtest_env}"
            " {2} -o {3} {4}"
        )

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '64' if 64 in ispec['supported_xlen'] else '32'
        abi = 'lp64' if self.xlen == '64' else 'ilp32'
        self.compile_cmd += f" -mabi={abi}"

        # Override SET_REL_TVAL_MSK for NEORV32 (MTVAL always zero for these causes)
        self.compile_cmd += (
            ' \"-DSET_REL_TVAL_MSK=('
            '(1<<CAUSE_MISALIGNED_LOAD)'
            '|(1<<CAUSE_LOAD_ACCESS)'
            '|(1<<CAUSE_MISALIGNED_STORE)'
            '|(1<<CAUSE_STORE_ACCESS)'
            ')\"'
        )

    def runTests(self, testList):
        for testname in testList:
            logger.debug(f"Running Test: {testname} on DUT")
            testentry = testList[testname]

            test      = testentry['test_path']
            test_dir  = testentry['work_dir']
            elf       = os.path.join(test_dir, 'main.elf')
            bin_file  = os.path.join(test_dir, 'main.bin')
            sig_file  = os.path.join(test_dir, self.name[:-1] + ".signature")

            compile_macros = ' -D' + ' -D'.join(testentry['macros'])
            marchstr = testentry['isa'].lower()

            # ── Compile ───────────────────────────────────────────────────
            cmd = self.compile_cmd.format(
                marchstr, self.xlen, test, elf, compile_macros)
            logger.debug("DUT compile: " + cmd)
            utils.shellCommand(cmd).run(cwd=test_dir)

            # ── ELF → flat binary → hex ───────────────────────────────────
            cmd = (f"{RVGCCPREFIX}objcopy"
                   f" -O binary {elf} {bin_file}")
            logger.debug("DUT objcopy: " + cmd)
            utils.shellCommand(cmd).run()

            # optional disassembly for debugging (skipped if no objdump found)
            for od in (f"{RVGCCPREFIX}objdump", "riscv64-unknown-elf-objdump",
                       "riscv32-unknown-elf-objdump", "objdump"):
                exe = shutil.which(od)
                if exe:
                    try:
                        dis = subprocess.run([exe, "-d", elf], capture_output=True,
                                             text=True, timeout=60).stdout
                        if dis.strip():
                            with open(os.path.join(test_dir, "main.dis"), "w") as f:
                                f.write(dis)
                            break
                    except Exception:
                        pass

            hex_file = os.path.join(test_dir, 'main.hex')
            bin_to_hex(bin_file, hex_file)

            # ── Simulate ──────────────────────────────────────────────────
            sig_name = os.path.basename(sig_file)
            cmd = (
                f"{GHDLEXE} -r --std=08 -frelaxed"
                f" --workdir={self.ghdl_work}"
                f" {TESTBENCH}"
                f" -gTEST_DIR={test_dir}/"
                f" -gHEX_FILE=main.hex"
                f" -gBUS_LOG=bus.log"
                f" -gSIG_FILE={sig_name}"
                f" -gMEM_SIZE={MEM_SIZE}"
                f" -gTIMEOUT_CYCLES={TIMEOUT_CYC}"
                f" --max-stack-alloc=0"
                f" --ieee-asserts=disable"
                f" --assert-level=error"
            )
            logger.debug("DUT simulate: " + cmd)
            utils.shellCommand(cmd).run()

        if not self.target_run:
            raise SystemExit
