cd ./riscv-dv
python3 run.py \
  --iss spike,rv \
  --target rv32i \
  --testlist target/rv32i_ghdl/testlist.yaml \
  --mabi ilp32 \
  --test riscv_arithmetic_basic_test \
  --iterations 10 \
  --simulator pyflow \
  --iss_timeout 600 \
  -o output/run_030 2>&1 | tail -50