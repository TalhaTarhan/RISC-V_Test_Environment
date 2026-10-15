library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_rv32i is
  generic (
    HEXFILE    : string  := "test.hex";
    TRACEFILE  : string  := "trace.log";
    MAX_CYCLES : integer := 2000000
  );
end entity;

architecture sim of tb_rv32i is

  signal clk_i      : std_logic := '0';
  signal rstn_i     : std_logic := '0';
  signal xbus_adr_o : std_logic_vector(31 downto 0);
  signal xbus_dat_o : std_logic_vector(31 downto 0);
  signal xbus_we_o  : std_logic;
  signal xbus_sel_o : std_logic_vector(3 downto 0);
  signal xbus_stb_o : std_logic;
  signal xbus_cyc_o : std_logic;
  signal xbus_dat_i : std_logic_vector(31 downto 0) := (others => '0');
  signal xbus_ack_i : std_logic := '0';
  signal xbus_err_i : std_logic := '0';

  constant MEM_WORDS : natural := 65536; -- 256KB
  type mem_t is array(0 to MEM_WORDS-1) of std_logic_vector(31 downto 0);
  shared variable mem : mem_t := (others => (others => '0'));

  signal sim_done : boolean := false;

  -- Debug/trace signals (DUT'tan)
  signal dbg_valid : std_logic;
  signal dbg_pc    : std_logic_vector(31 downto 0);
  signal dbg_instr : std_logic_vector(31 downto 0);
  signal dbg_rd_we : std_logic;
  signal dbg_rd    : std_logic_vector(4  downto 0);
  signal dbg_wdata : std_logic_vector(31 downto 0);

  -- 4-bit nibble → integer (max 15, overflow yok)
  function nibble_to_int(v : std_logic_vector(3 downto 0)) return integer is
    variable r : integer := 0;
  begin
    if v(3) = '1' then r := r + 8; end if;
    if v(2) = '1' then r := r + 4; end if;
    if v(1) = '1' then r := r + 2; end if;
    if v(0) = '1' then r := r + 1; end if;
    return r;
  end function;

  -- 16-bit → integer (max 65535, overflow yok)
  function slv16_to_int(v : std_logic_vector(15 downto 0)) return integer is
    variable r : integer := 0;
  begin
    for i in 15 downto 0 loop
      r := r * 2;
      if v(i) = '1' then r := r + 1; end if;
    end loop;
    return r;
  end function;

  -- Word index: adr(17 downto 2) → 0..65535
  function addr_to_widx(adr : std_logic_vector(31 downto 0)) return integer is
    variable idx : integer;
  begin
    idx := slv16_to_int(adr(17 downto 2));
    if idx >= MEM_WORDS then idx := 0; end if;
    return idx;
  end function;

  -- 32-bit SLV → 8-char hex string, nibble nibble (max 15 per step)
  function to_hstr(v : std_logic_vector(31 downto 0)) return string is
    constant H : string(1 to 16) := "0123456789abcdef";
    variable r : string(1 to 8);
    variable n : integer;
  begin
    for i in 1 to 8 loop
      n    := nibble_to_int(v(35-i*4 downto 32-i*4));
      r(i) := H(n+1);
    end loop;
    return r;
  end function;

  -- 5-bit rd → integer (max 31)
  function rd_to_int(v : std_logic_vector(4 downto 0)) return integer is
    variable r : integer := 0;
  begin
    if v(4) = '1' then r := r + 16; end if;
    if v(3) = '1' then r := r + 8;  end if;
    if v(2) = '1' then r := r + 4;  end if;
    if v(1) = '1' then r := r + 2;  end if;
    if v(0) = '1' then r := r + 1;  end if;
    return r;
  end function;

begin

  dut: entity work.neorv32_top
    port map(
      clk_i      => clk_i,      rstn_i     => rstn_i,
      xbus_adr_o => xbus_adr_o, xbus_dat_o => xbus_dat_o,
      xbus_we_o  => xbus_we_o,  xbus_sel_o => xbus_sel_o,
      xbus_stb_o => xbus_stb_o, xbus_cyc_o => xbus_cyc_o,
      xbus_dat_i => xbus_dat_i, xbus_ack_i => xbus_ack_i,
      xbus_err_i => xbus_err_i,
      irq_msi_i  => '0', irq_mti_i => '0', irq_mei_i => '0',
      dbg_valid_o => dbg_valid, dbg_pc_o    => dbg_pc,
      dbg_instr_o => dbg_instr, dbg_rd_we_o => dbg_rd_we,
      dbg_rd_o    => dbg_rd,    dbg_wdata_o => dbg_wdata
    );

  clk_i <= not clk_i after 5 ns when not sim_done else '0';

  -- Reset + hex yükleme
  init_proc: process
    file     f    : text;
    variable ln   : line;
    variable s    : string(1 to 8);
    variable addr : integer := 0;
    variable b0, b1, b2, b3 : integer; -- her byte ayrı, max 255

    function hx(c : character) return integer is
    begin
      case c is
        when '0'=>return 0; when '1'=>return 1; when '2'=>return 2;
        when '3'=>return 3; when '4'=>return 4; when '5'=>return 5;
        when '6'=>return 6; when '7'=>return 7; when '8'=>return 8;
        when '9'=>return 9; when 'a'|'A'=>return 10; when 'b'|'B'=>return 11;
        when 'c'|'C'=>return 12; when 'd'|'D'=>return 13;
        when 'e'|'E'=>return 14; when 'f'|'F'=>return 15;
        when others=>return 0;
      end case;
    end function;

  begin
    rstn_i <= '0';
    wait for 200 ns;
    file_open(f, HEXFILE, read_mode);
    while not endfile(f) and addr < MEM_WORDS loop
      readline(f, ln);
      if ln'length >= 8 then
        read(ln, s);
        -- Her byte'ı ayrı hesapla, max 255 — overflow yok
        b3 := hx(s(1)) * 16 + hx(s(2)); -- MSB
        b2 := hx(s(3)) * 16 + hx(s(4));
        b1 := hx(s(5)) * 16 + hx(s(6));
        b0 := hx(s(7)) * 16 + hx(s(8)); -- LSB
        mem(addr) := std_logic_vector(to_unsigned(b3, 8)) &
                     std_logic_vector(to_unsigned(b2, 8)) &
                     std_logic_vector(to_unsigned(b1, 8)) &
                     std_logic_vector(to_unsigned(b0, 8));
        addr := addr + 1;
      end if;
    end loop;
    file_close(f);
    wait for 10 ns;
    rstn_i <= '1';
    wait;
  end process;

  -- Wishbone bellek slave
  wb_proc: process
    variable widx : integer;
  begin
    wait until rising_edge(clk_i);
    xbus_ack_i <= '0';
    xbus_err_i <= '0';
    if rstn_i = '1' and xbus_stb_o = '1' and xbus_cyc_o = '1' and
       xbus_ack_i = '0' and xbus_adr_o(31 downto 18) = "10000000000000" then
      widx := addr_to_widx(xbus_adr_o);
      if xbus_we_o = '0' then
        xbus_dat_i <= mem(widx);
      else
        if xbus_sel_o(0)='1' then mem(widx)(7  downto 0)  := xbus_dat_o(7  downto 0);  end if;
        if xbus_sel_o(1)='1' then mem(widx)(15 downto 8)  := xbus_dat_o(15 downto 8);  end if;
        if xbus_sel_o(2)='1' then mem(widx)(23 downto 16) := xbus_dat_o(23 downto 16); end if;
        if xbus_sel_o(3)='1' then mem(widx)(31 downto 24) := xbus_dat_o(31 downto 24); end if;
      end if;
      xbus_ack_i <= '1';
    end if;
  end process;

  -- Trace log — commit-accurate, doğrudan DUT debug portlarından
  trace_proc: process
    file     tf  : text open write_mode is TRACEFILE;
    variable L   : line;
    variable cnt : integer := 0;
  begin
    wait until rstn_i = '1';
    loop
      wait until rising_edge(clk_i);
      cnt := cnt + 1;
      if dbg_valid = '1' then
        if dbg_rd_we = '1' then
          write(L, string'("core   0: 0x") & to_hstr(dbg_pc)    &
                   string'(" (0x")         & to_hstr(dbg_instr) &
                   string'(") x")          & integer'image(rd_to_int(dbg_rd)) &
                   string'("=0x")          & to_hstr(dbg_wdata));
        else
          write(L, string'("core   0: 0x") & to_hstr(dbg_pc) &
                   string'(" (0x")         & to_hstr(dbg_instr) &
                   string'(")"));
        end if;
        writeline(tf, L);
      end if;
      if cnt >= MAX_CYCLES then
        write(L, string'("[TB] TIMEOUT after ") & integer'image(MAX_CYCLES) & string'(" cycles"));
        writeline(tf, L);
        sim_done <= true;
        wait;
      end if;
    end loop;
  end process;

end architecture sim;
