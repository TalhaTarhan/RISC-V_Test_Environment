cd ./riscv-dv

export RISCV_BIN="$HOME/riscof_env/riscv-gcc/bin"
export PATH="$RISCV_BIN:$HOME/riscof_env/spike/bin:$PATH"
export RISCV_GCC="$RISCV_BIN/riscv32-unknown-elf-gcc"
export RISCV_OBJCOPY="$RISCV_BIN/riscv32-unknown-elf-objcopy"
export SPIKE_PATH="$HOME/riscof_env/spike/bin"
export LD_LIBRARY_PATH="$HOME/riscof_env/spike/lib:${LD_LIBRARY_PATH:-}"
export RV_PATH="./riscof/plugins/rv32_dut"

for t in "$RISCV_BIN"/riscv32-unknown-elf-*; do
  a="$RISCV_BIN/riscv-none-elf-${t##*/riscv32-unknown-elf-}"; [ -e "$a" ] || ln -s "$t" "$a"
done

ls -l "$RISCV_GCC" "$RISCV_OBJCOPY" "$SPIKE_PATH/spike"; which riscv-none-elf-gcc

source ~/riscof_env/env.sh

python3 run.py \
  --iss spike,rv \
  --target rv32i \
  --testlist target/rv32i_ghdl/testlist.yaml \
  --mabi ilp32 \
  --test riscv_arithmetic_basic_test \
  --iterations 1 \
  --simulator pyflow \
  --iss_timeout 600 \
  -o output/run_031 2>&1 | tail -50
