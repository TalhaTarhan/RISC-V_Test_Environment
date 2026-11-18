cd ./riscof
source ~/riscof_env/env.sh
riscof run --config=config.ini --suite=riscv-arch-test --env=riscv-arch-test/riscv-test-suite/env
