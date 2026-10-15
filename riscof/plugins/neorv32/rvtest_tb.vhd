-- =============================================================================
-- tb_riscof.vhd
-- RISCOF testbench for neorv32_top (RV32I + Zicsr, Wishbone classic)
-- Standard : VHDL-2008 (ghdl --std=08 -frelaxed)
--
-- Features
--   * Single Wishbone classic slave memory (instr + data), byte-lane writes
--   * Memory is loaded from a text file: one 32-bit hex word per line,
--     first word at BASE_ADDR. Optional "@<word index hex>" lines relocate.
--   * NEORV32 test protocol (model_test.h) via a virtual device at HOST_BASE:
--         +0  write : signature start address
--         +4  write : signature end address
--         +8  write : any value ends the test (RVMODEL_HALT / boot trap)
--         +12 write : bit 11 drives irq_mei_i
--   * On end (or timeout) the signature [start, end) is dumped,
--     one 8-digit lowercase hex word per line (RISCOF format)
--   * Optional random wait states (WAIT_MIN..WAIT_MAX) on every bus access
--   * Access outside memory and the host device is answered with err_i
--
-- Example:
--   ghdl -a --std=08 -frelaxed rv32_top.vhd tb_riscof.vhd
--   ghdl -e --std=08 -frelaxed tb_riscof
--   ghdl -r --std=08 -frelaxed tb_riscof \
--        -gHEX_FILE=my.hex -gSIG_FILE=DUT-core.signature \
--        -gWAIT_MAX=3
--
-- TEST_DIR : optional directory; prepended to HEX_FILE and SIG_FILE
--            (a "/" is inserted if missing).
-- MEM_SIZE : memory size in bytes (overrides MEM_WORDS when > 0).
--
-- Address generics are hex strings without "0x" (ghdl -g cannot pass 32-bit
-- vectors). SEED must be > 0.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library std;
use std.textio.all;
use std.env.all;

entity rvtest_tb is
  generic (
    TEST_DIR       : string  := "";            -- prefix for HEX/SIG/TRACE files
    HEX_FILE       : string  := "program.hex";
    BUS_LOG        : string  := "";            -- "" = off; else log every bus access here
    BUS_LOG_MAX    : integer := 3000;          -- max logged accesses
    BUS_ERR_LIMIT  : integer := 16;            -- abort after this many consecutive bus errors
    SIG_FILE       : string  := "DUT-core.signature";
    SIG_START      : string  := "";            -- fallback if the core never writes it
    SIG_END        : string  := "";            -- fallback if the core never writes it
    HOST_BASE      : string  := "F0000000";    -- virtual test-control device
    BASE_ADDR      : string  := "80000000";
    MEM_SIZE       : integer := 0;             -- memory size in BYTES (0 = use MEM_WORDS)
    MEM_WORDS      : integer := 1048576;       -- 4 MiB, used when MEM_SIZE = 0
    WAIT_MIN       : integer := 0;             -- wait states per access
    WAIT_MAX       : integer := 0;
    SEED           : integer := 1;
    TIMEOUT_CYCLES : integer := 50000000
  );
end entity rvtest_tb;

architecture sim of rvtest_tb is

  constant CLK_T : time := 10 ns;

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';

  -- Wishbone
  signal wb_adr   : std_logic_vector(31 downto 0);
  signal wb_dat_o : std_logic_vector(31 downto 0);  -- master -> slave
  signal wb_we    : std_logic;
  signal wb_sel   : std_logic_vector(3 downto 0);
  signal wb_stb   : std_logic;
  signal wb_cyc   : std_logic;
  signal wb_dat_i : std_logic_vector(31 downto 0) := (others => '0');
  signal wb_ack   : std_logic := '0';
  signal wb_err   : std_logic := '0';
  signal irq_mei  : std_logic := '0';

  -- --------------------------------------------------------------------------
  -- Helpers
  -- --------------------------------------------------------------------------
  function join_path(d : string; f : string) return string is
  begin
    if d'length = 0 then
      return f;
    elsif d(d'right) = '/' then
      return d & f;
    else
      return d & "/" & f;
    end if;
  end function;

  function calc_words return integer is
  begin
    if MEM_SIZE > 0 then
      return (MEM_SIZE + 3) / 4;
    else
      return MEM_WORDS;
    end if;
  end function;

  constant NWORDS     : integer := calc_words;
  constant HEX_PATH   : string  := join_path(TEST_DIR, HEX_FILE);
  constant SIG_PATH   : string  := join_path(TEST_DIR, SIG_FILE);
  constant LOG_PATH   : string  := join_path(TEST_DIR, BUS_LOG);

  function hex_val(c : character) return integer is
  begin
    case c is
      when '0' to '9' => return character'pos(c) - character'pos('0');
      when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
      when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
      when others     => return -1;
    end case;
  end function;

  -- parses hex digits (other characters such as 'x', '_', CR are ignored)
  function hex_to_u32(s : string) return unsigned is
    variable v : unsigned(31 downto 0) := (others => '0');
    variable h : integer;
  begin
    for i in s'range loop
      h := hex_val(s(i));
      if h >= 0 then
        v := shift_left(v, 4) or to_unsigned(h, 32);
      end if;
    end loop;
    return v;
  end function;

  function has_hex(s : string) return boolean is
  begin
    for i in s'range loop
      if hex_val(s(i)) >= 0 then
        return true;
      end if;
    end loop;
    return false;
  end function;

  function to_hex8(v : std_logic_vector(31 downto 0)) return string is
    constant digits : string(1 to 16) := "0123456789abcdef";
    variable r : string(1 to 8);
    variable n : integer;
  begin
    for i in 0 to 7 loop
      n := to_integer(unsigned(to_01(v(31 - 4*i downto 28 - 4*i), '0')));
      r(i + 1) := digits(n + 1);
    end loop;
    return r;
  end function;

begin

  -- --------------------------------------------------------------------------
  -- Clock / reset
  -- --------------------------------------------------------------------------
  clk  <= not clk after CLK_T / 2;
  rstn <= '0', '1' after 10 * CLK_T + 1 ns;

  -- --------------------------------------------------------------------------
  -- DUT
  -- --------------------------------------------------------------------------
  dut : entity work.neorv32_top
    port map (
      clk_i       => clk,
      rstn_i      => rstn,
      xbus_adr_o  => wb_adr,
      xbus_dat_o  => wb_dat_o,
      xbus_we_o   => wb_we,
      xbus_sel_o  => wb_sel,
      xbus_stb_o  => wb_stb,
      xbus_cyc_o  => wb_cyc,
      xbus_dat_i  => wb_dat_i,
      xbus_ack_i  => wb_ack,
      xbus_err_i  => wb_err,
      irq_msi_i   => '0',
      irq_mti_i   => '0',
      irq_mei_i   => irq_mei
    );

  -- --------------------------------------------------------------------------
  -- Memory + Wishbone slave + test control
  -- --------------------------------------------------------------------------
  mem_proc : process
    type mem_t is array (0 to NWORDS - 1) of std_logic_vector(31 downto 0);
    variable mem : mem_t := (others => (others => '0'));

    constant BASE      : unsigned(31 downto 0) := hex_to_u32(BASE_ADDR);
    constant HOST      : unsigned(31 downto 0) := hex_to_u32(HOST_BASE);
    constant MEM_BYTES : unsigned(31 downto 0) := to_unsigned(NWORDS * 4, 32);

    variable seed1   : positive := SEED;
    variable seed2   : positive := SEED + 7;
    variable rnd     : real;
    variable pending : boolean := false;
    variable cnt     : integer := 0;
    variable cycles  : integer := 0;
    variable a, off  : unsigned(31 downto 0);
    variable idx     : integer;
    variable w       : std_logic_vector(31 downto 0);
    variable halt    : boolean;
    variable nlog    : integer := 0;
    variable nerr    : integer := 0;
    variable ll      : line;
    file     bf      : text;
    variable bst     : file_open_status;
    variable sig_s   : unsigned(31 downto 0) := hex_to_u32(SIG_START);
    variable sig_e   : unsigned(31 downto 0) := hex_to_u32(SIG_END);

    -- ---- load hex file ----
    procedure load_hex is
      file     f    : text;
      variable st   : file_open_status;
      variable l    : line;
      variable widx : integer := 0;
      variable s    : string(1 to 256);
      variable s_len: integer;
    begin
      file_open(st, f, HEX_PATH, read_mode);
      if st /= open_ok then
        report "Cannot open HEX_FILE: " & HEX_PATH severity failure;
        return;
      end if;
      while not endfile(f) loop
        readline(f, l);
        if l /= null and l'length > 0 then
          s_len := l'length;
          s(1 to s_len) := l.all;
          if s(1) = '#' or s(1) = '/' then
            null;                                   -- comment line
          elsif s(1) = '@' then
            if s_len > 1 and has_hex(s(2 to s_len)) then
              widx := to_integer(hex_to_u32(s(2 to s_len)));
            end if;
          elsif has_hex(s(1 to s_len)) then
            if widx < NWORDS then
              mem(widx) := std_logic_vector(hex_to_u32(s(1 to s_len)));
            else
              report "HEX_FILE larger than memory" severity failure;
            end if;
            widx := widx + 1;
          end if;
        end if;
        if l /= null then
          deallocate(l);
        end if;
      end loop;
      file_close(f);
    end procedure;

    -- ---- dump signature ----
    procedure dump_sig is
      file     f   : text;
      variable st  : file_open_status;
      variable l   : line;
      variable sa  : unsigned(31 downto 0);
      variable se  : unsigned(31 downto 0);
      variable o   : unsigned(31 downto 0);
    begin
      file_open(st, f, SIG_PATH, write_mode);
      if st /= open_ok then
        report "Cannot open SIG_FILE: " & SIG_PATH severity failure;
        return;
      end if;
      sa := sig_s;
      se := sig_e;
      if se = sa then
        report "Signature range is empty (start=end=0x" &
               to_hex8(std_logic_vector(sa)) & ")" severity warning;
      end if;
      if se < sa then
        report "SIG_END < SIG_START" severity error;
      end if;
      while sa < se loop
        o := sa - BASE;
        if o < MEM_BYTES then
          write(l, to_hex8(mem(to_integer(o(31 downto 2)))));
        else
          report "Signature address outside memory" severity warning;
          write(l, string'("00000000"));
        end if;
        writeline(f, l);
        sa := sa + 4;
      end loop;
      file_close(f);
    end procedure;

  begin
    load_hex;
    if BUS_LOG'length > 0 then
      file_open(bst, bf, LOG_PATH, write_mode);
    end if;

    loop
      wait until rising_edge(clk);

      if rstn = '0' then
        wb_ack  <= '0';
        wb_err  <= '0';
        pending := false;

      else
        cycles := cycles + 1;
        if cycles >= TIMEOUT_CYCLES then
          report "TIMEOUT after " & integer'image(cycles) &
                 " cycles, test never signalled the end" severity error;
          dump_sig;
          finish(1);
          wait;
        end if;

        if wb_ack = '1' or wb_err = '1' then
          -- terminate the response pulse; do not start a new access this cycle
          wb_ack <= '0';
          wb_err <= '0';

        elsif wb_cyc = '1' and wb_stb = '1' then
          if not pending then
            pending := true;
            if WAIT_MAX > WAIT_MIN then
              uniform(seed1, seed2, rnd);
              cnt := WAIT_MIN + integer(floor(rnd * real(WAIT_MAX - WAIT_MIN + 1)));
              if cnt > WAIT_MAX then
                cnt := WAIT_MAX;
              end if;
            else
              cnt := WAIT_MIN;
            end if;
          end if;

          if cnt > 0 then
            cnt := cnt - 1;
          else
            pending := false;
            a    := unsigned(wb_adr);
            off  := a - BASE;
            halt := false;

            if BUS_LOG'length > 0 and nlog < BUS_LOG_MAX and bst = open_ok then
              nlog := nlog + 1;
              if wb_we = '1' then
                write(ll, "W " & to_hex8(wb_adr) & " data=" & to_hex8(wb_dat_o) &
                          " sel=" & to_string(wb_sel));
              elsif off < MEM_BYTES then
                write(ll, "R " & to_hex8(wb_adr) & " data=" &
                          to_hex8(mem(to_integer(off(31 downto 2)))));
              else
                write(ll, "R " & to_hex8(wb_adr) & " (outside memory)");
              end if;
              writeline(bf, ll);
            end if;

            if a(31 downto 4) = HOST(31 downto 4) then
              -- virtual test-control device
              if wb_we = '1' then
                case to_integer(a(3 downto 2)) is
                  when 0      => sig_s := unsigned(wb_dat_o);
                  when 1      => sig_e := unsigned(wb_dat_o);
                  when 2      => halt := true;
                  when others => irq_mei <= wb_dat_o(11);
                end case;
              else
                wb_dat_i <= (others => '0');
              end if;
              nerr := 0;
              wb_ack <= '1';
            elsif off < MEM_BYTES then
              idx := to_integer(off(31 downto 2));
              if wb_we = '1' then
                w := mem(idx);
                for b in 0 to 3 loop
                  if wb_sel(b) = '1' then
                    w(8*b + 7 downto 8*b) := wb_dat_o(8*b + 7 downto 8*b);
                  end if;
                end loop;
                mem(idx) := w;
              else
                wb_dat_i <= mem(idx);
              end if;
              nerr := 0;
              wb_ack <= '1';
            else
              nerr := nerr + 1;
              if nerr = BUS_ERR_LIMIT then
                report "ABORT: core is stuck on bus errors (last adr=0x" &
                       to_hex8(wb_adr) & "); it probably trapped with mtvec=0 " &
                       "(e.g. CSR instruction not supported)" severity error;
                dump_sig;
                finish(1);
                wait;
              end if;
              report "Bus access outside memory: adr=" & to_hex8(wb_adr) &
                     " we=" & std_logic'image(wb_we) severity warning;
              wb_err <= '1';
            end if;

            if halt then
              report "test end signalled after " & integer'image(cycles) &
                     " cycles, signature 0x" & to_hex8(std_logic_vector(sig_s)) &
                     "..0x" & to_hex8(std_logic_vector(sig_e)) severity note;
              dump_sig;
              finish(0);
              wait;
            end if;
          end if;

        else
          pending := false;
        end if;
      end if;
    end loop;
  end process mem_proc;

end architecture sim;
