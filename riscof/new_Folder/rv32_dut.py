# =============================================================================
# rv32_dut.py  -  RISCOF DUT plugin  (GHDL simulator, .signature output)
# =============================================================================
import os
import subprocess
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class rv32_dut(pluginTemplate):
    __model__   = "rv32_dut"
    __version__ = "1.0.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.plugin_dir = os.path.dirname(os.path.abspath(__file__))
        self.repo_root  = os.path.abspath(os.path.join(self.plugin_dir, "..", ".."))
        self.dut_vhd    = os.path.join(self.repo_root, "rtl", "rv32_dut.vhd")
        self.tb_vhd     = os.path.join(self.repo_root, "sim", "tb_rv32_dut_riscof.vhd")
        cfg = self.pluginConfig
        self.riscv_prefix = cfg.get("riscv_prefix", fallback="riscv32-unknown-elf-")
        self.ghdl_bin     = cfg.get("ghdl",         fallback="ghdl")
        self.objcopy_bin  = self.riscv_prefix + "objcopy"
        self.sim_timeout  = int(cfg.get("timeout_ns", fallback="100000000"))
        self.work_dir      = None
        self.ghdl_work_dir = None

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir      = work_dir
        self.suite         = suite
        self.isa_spec      = os.path.join(self.plugin_dir, "rv32_dut_isa.yaml")
        self.platform_spec = os.path.join(self.plugin_dir, "rv32_dut_platform.yaml")
        self.ghdl_work_dir = os.path.join(work_dir, "ghdl_work")
        os.makedirs(self.ghdl_work_dir, exist_ok=True)

    def build(self, bld_dir):
        logger.info("rv32_dut: Analysing VHDL with GHDL ...")
        def ghdl_a(f):
            cmd = [self.ghdl_bin, "-a", "--std=93",
                   "--workdir=" + self.ghdl_work_dir, f]
            ret = subprocess.run(cmd, capture_output=True, text=True)
            if ret.returncode != 0:
                raise Exception(f"GHDL -a failed for {f}:\n{ret.stderr}")
        ghdl_a(self.dut_vhd)
        ghdl_a(self.tb_vhd)
        cmd = [self.ghdl_bin, "-e", "--std=93",
               "--workdir=" + self.ghdl_work_dir, "tb_rv32_dut_riscof"]
        ret = subprocess.run(cmd, capture_output=True, text=True,
                             cwd=self.ghdl_work_dir)
        if ret.returncode != 0:
            raise Exception(f"GHDL -e failed:\n{ret.stderr}")
        logger.info("rv32_dut: GHDL build complete.")

    def runTests(self, test_list):
        for test_name, test_data in test_list.items():
            test_dir = test_data["work_dir"]
            elf_file = test_data["compiled_elf"]
            sig_file = test_data["result_file"]
            os.makedirs(test_dir, exist_ok=True)
            logger.info(f"rv32_dut: {test_name}")

            bin_file = os.path.join(test_dir, "test.bin")
            ret = subprocess.run(
                [self.objcopy_bin, "-O", "binary", elf_file, bin_file],
                capture_output=True, text=True)
            if ret.returncode != 0:
                raise Exception(f"objcopy failed: {ret.stderr}")

            cmd = [
                self.ghdl_bin, "-r", "--std=93",
                "--workdir=" + self.ghdl_work_dir,
                "tb_rv32_dut_riscof",
                f"--stop-time={self.sim_timeout}ns",
                f"-gBIN_FILE={bin_file}",
                f"-gSIG_FILE={sig_file}",
            ]
            ret = subprocess.run(cmd, capture_output=True, text=True,
                                 cwd=self.ghdl_work_dir)

            if not os.path.isfile(sig_file):
                logger.error(
                    f"rv32_dut: no .signature for {test_name} "
                    f"rc={ret.returncode}\n{ret.stdout}\n{ret.stderr}")
                open(sig_file, "w").close()
            else:
                logger.info(f"rv32_dut: .signature -> {sig_file}")
