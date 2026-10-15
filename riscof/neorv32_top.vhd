-- =============================================================================
-- neorv32_top.vhd
-- RV32I + Zicsr core for RISCOF testing
-- Instructions: RV32I base set + CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI
--               + ECALL/EBREAK + MRET
-- Standard : VHDL-2008 (ghdl --std=08 -frelaxed)
-- Bus      : Wishbone B4 classic
-- Reset    : Asynchronous, active-low; PC resets to 0x80000000
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity neorv32_top is
  port (
    clk_i      : in  std_logic;
    rstn_i     : in  std_logic;
    xbus_adr_o : out std_logic_vector(31 downto 0);
    xbus_dat_o : out std_logic_vector(31 downto 0);
    xbus_we_o  : out std_logic;
    xbus_sel_o : out std_logic_vector(3 downto 0);
    xbus_stb_o : out std_logic;
    xbus_cyc_o : out std_logic;
    xbus_dat_i : in  std_logic_vector(31 downto 0) := (others => '0');
    xbus_ack_i : in  std_logic := '0';
    xbus_err_i : in  std_logic := '0';
    irq_msi_i  : in  std_logic := '0';
    irq_mti_i  : in  std_logic := '0';
    irq_mei_i  : in  std_logic := '0';
    -- Debug/trace ports (commit-accurate)
    dbg_valid_o : out std_logic;
    dbg_pc_o    : out std_logic_vector(31 downto 0);
    dbg_instr_o : out std_logic_vector(31 downto 0);
    dbg_rd_we_o : out std_logic;
    dbg_rd_o    : out std_logic_vector(4  downto 0);
    dbg_wdata_o : out std_logic_vector(31 downto 0)
  );
end entity neorv32_top;

architecture rtl of neorv32_top is

  -- --------------------------------------------------------------------------
  -- Constants
  -- --------------------------------------------------------------------------
  constant RESET_VECTOR : std_logic_vector(31 downto 0) := x"80000000";

  -- Debug/trace signals
  signal dbg_valid : std_logic := '0';
  signal dbg_pc    : std_logic_vector(31 downto 0) := (others => '0');
  signal dbg_instr : std_logic_vector(31 downto 0) := (others => '0');
  signal dbg_rd_we : std_logic := '0';
  signal dbg_rd    : std_logic_vector(4  downto 0) := (others => '0');
  signal dbg_wdata : std_logic_vector(31 downto 0) := (others => '0');

  -- CSR addresses
  constant CSR_MSTATUS  : std_logic_vector(11 downto 0) := x"300";
  constant CSR_MISA     : std_logic_vector(11 downto 0) := x"301";
  constant CSR_MIE      : std_logic_vector(11 downto 0) := x"304";
  constant CSR_MTVEC    : std_logic_vector(11 downto 0) := x"305";
  constant CSR_MSCRATCH : std_logic_vector(11 downto 0) := x"340";
  constant CSR_MEPC     : std_logic_vector(11 downto 0) := x"341";
  constant CSR_MCAUSE   : std_logic_vector(11 downto 0) := x"342";
  constant CSR_MTVAL    : std_logic_vector(11 downto 0) := x"343";
  constant CSR_MIP      : std_logic_vector(11 downto 0) := x"344";
  constant CSR_MVENDORID: std_logic_vector(11 downto 0) := x"F11";
  constant CSR_MARCHID  : std_logic_vector(11 downto 0) := x"F12";
  constant CSR_MIMPID   : std_logic_vector(11 downto 0) := x"F13";
  constant CSR_MHARTID  : std_logic_vector(11 downto 0) := x"F14";

  -- misa: RV32I
  constant MISA_VAL : std_logic_vector(31 downto 0) := x"40000100";

  -- --------------------------------------------------------------------------
  -- Register file
  -- --------------------------------------------------------------------------
  type regfile_t is array (0 to 31) of std_logic_vector(31 downto 0);
  signal rf : regfile_t := (others => (others => '0'));

  -- --------------------------------------------------------------------------
  -- CSRs
  -- --------------------------------------------------------------------------
  signal reg_mstatus  : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mie      : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mtvec    : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mscratch : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mepc     : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mcause   : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mtval    : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_mip      : std_logic_vector(31 downto 0) := (others => '0');

  -- --------------------------------------------------------------------------
  -- PC
  -- --------------------------------------------------------------------------
  signal pc      : std_logic_vector(31 downto 0) := RESET_VECTOR;
  signal pc_next : std_logic_vector(31 downto 0);

  -- --------------------------------------------------------------------------
  -- FSM
  -- --------------------------------------------------------------------------
  type state_t is (S_FETCH, S_FETCH_WAIT, S_EXEC, S_MEM_WAIT, S_TRAP, S_MRET);
  signal state : state_t := S_FETCH;

  -- --------------------------------------------------------------------------
  -- Instruction register
  -- --------------------------------------------------------------------------
  signal instr : std_logic_vector(31 downto 0) := (others => '0');

  -- --------------------------------------------------------------------------
  -- Decode signals
  -- --------------------------------------------------------------------------
  signal opcode  : std_logic_vector(6 downto 0);
  signal rd      : std_logic_vector(4 downto 0);
  signal rs1     : std_logic_vector(4 downto 0);
  signal funct3  : std_logic_vector(2 downto 0);
  signal funct7  : std_logic_vector(6 downto 0);
  signal csr_adr : std_logic_vector(11 downto 0);

  signal imm_i   : std_logic_vector(31 downto 0);
  signal imm_s   : std_logic_vector(31 downto 0);
  signal imm_b   : std_logic_vector(31 downto 0);
  signal imm_u   : std_logic_vector(31 downto 0);
  signal imm_j   : std_logic_vector(31 downto 0);
  signal imm_z   : std_logic_vector(31 downto 0); -- zero-extended rs1 for CSRxI

  -- Operands
  signal op_a    : std_logic_vector(31 downto 0);
  signal op_b    : std_logic_vector(31 downto 0);

  -- ALU / CSR results
  signal alu_res    : std_logic_vector(31 downto 0);
  signal csr_rdata  : std_logic_vector(31 downto 0);

  -- Control
  signal branch_taken : std_logic;
  signal take_trap    : std_logic;
  signal take_mret    : std_logic;
  signal is_csr       : std_logic;
  signal trap_cause   : std_logic_vector(31 downto 0);
  signal trap_val     : std_logic_vector(31 downto 0);

  -- Memory access
  signal mem_addr    : std_logic_vector(31 downto 0);
  signal mem_wdata   : std_logic_vector(31 downto 0);
  signal mem_rdata   : std_logic_vector(31 downto 0);
  signal mem_we      : std_logic;
  signal mem_sel     : std_logic_vector(3 downto 0);
  signal mem_is_load : std_logic;
  signal mem_is_store: std_logic;

  -- Wishbone internal
  signal wb_cyc  : std_logic;
  signal wb_stb  : std_logic;
  signal wb_we   : std_logic;
  signal wb_adr  : std_logic_vector(31 downto 0);
  signal wb_dato : std_logic_vector(31 downto 0);
  signal wb_sel  : std_logic_vector(3 downto 0);

  -- --------------------------------------------------------------------------
  -- Helpers
  -- --------------------------------------------------------------------------
  function sign_ext(v : std_logic_vector; w : integer) return std_logic_vector is
    variable r : std_logic_vector(w-1 downto 0);
  begin
    r := (others => v(v'left));
    r(v'length-1 downto 0) := v;
    return r;
  end function;

  function sra32(val : std_logic_vector(31 downto 0);
                 shamt : std_logic_vector(4 downto 0))
                 return std_logic_vector is
    variable sv : signed(31 downto 0);
  begin
    sv := signed(val);
    return std_logic_vector(shift_right(sv, to_integer(unsigned(to_01(shamt, '0')))));
  end function;

begin

  -- --------------------------------------------------------------------------
  -- Decode
  -- --------------------------------------------------------------------------
  opcode  <= instr(6 downto 0);
  rd      <= instr(11 downto 7);
  funct3  <= instr(14 downto 12);
  rs1     <= instr(19 downto 15);
  funct7  <= instr(31 downto 25);
  csr_adr <= instr(31 downto 20);

  imm_i <= sign_ext(instr(31 downto 20), 32);
  imm_s <= sign_ext(instr(31 downto 25) & instr(11 downto 7), 32);
  imm_b <= sign_ext(instr(31) & instr(7) & instr(30 downto 25) &
                    instr(11 downto 8) & '0', 32);
  imm_u <= instr(31 downto 12) & x"000";
  imm_j <= sign_ext(instr(31) & instr(19 downto 12) & instr(20) &
                    instr(30 downto 21) & '0', 32);
  -- zero-extended rs1 field for CSRxxI instructions
  imm_z <= x"000000" & "000" & instr(19 downto 15);

  op_a <= rf(to_integer(unsigned(to_01(rs1, '0'))));
  op_b <= rf(to_integer(unsigned(to_01(instr(24 downto 20), '0'))));

  -- --------------------------------------------------------------------------
  -- CSR read (combinational)
  -- --------------------------------------------------------------------------
  csr_read_proc : process(csr_adr, reg_mstatus, reg_mie, reg_mtvec,
                          reg_mscratch, reg_mepc, reg_mcause, reg_mtval,
                          reg_mip)
  begin
    case csr_adr is
      when CSR_MSTATUS   => csr_rdata <= reg_mstatus;
      when CSR_MISA      => csr_rdata <= MISA_VAL;
      when CSR_MIE       => csr_rdata <= reg_mie;
      when CSR_MTVEC     => csr_rdata <= reg_mtvec;
      when CSR_MSCRATCH  => csr_rdata <= reg_mscratch;
      when CSR_MEPC      => csr_rdata <= reg_mepc;
      when CSR_MCAUSE    => csr_rdata <= reg_mcause;
      when CSR_MTVAL     => csr_rdata <= reg_mtval;
      when CSR_MIP       => csr_rdata <= reg_mip;
      when CSR_MVENDORID => csr_rdata <= (others => '0');
      when CSR_MARCHID   => csr_rdata <= (others => '0');
      when CSR_MIMPID    => csr_rdata <= (others => '0');
      when CSR_MHARTID   => csr_rdata <= (others => '0');
      when others        => csr_rdata <= (others => '0');
    end case;
  end process csr_read_proc;

  -- --------------------------------------------------------------------------
  -- ALU (combinational)
  -- --------------------------------------------------------------------------
  alu_proc : process(opcode, funct3, funct7, op_a, op_b, imm_i, imm_u,
                     imm_s, imm_b, imm_j, imm_z, pc, csr_rdata, csr_adr)
    variable shamt : std_logic_vector(4 downto 0);
    variable res   : std_logic_vector(31 downto 0);
    variable wdata : std_logic_vector(31 downto 0);
  begin
    shamt        := op_b(4 downto 0);
    res          := (others => '0');
    branch_taken <= '0';
    mem_is_load  <= '0';
    mem_is_store <= '0';
    mem_we       <= '0';
    mem_sel      <= "0000";
    mem_addr     <= (others => '0');
    mem_wdata    <= (others => '0');
    alu_res      <= (others => '0');
    take_trap    <= '0';
    take_mret    <= '0';
    is_csr       <= '0';
    trap_cause   <= (others => '0');
    trap_val     <= (others => '0');

    case opcode is

      -- LUI
      when "0110111" =>
        alu_res <= imm_u;

      -- AUIPC
      when "0010111" =>
        alu_res <= std_logic_vector(unsigned(pc) + unsigned(imm_u));

      -- JAL
      when "1101111" =>
        alu_res <= std_logic_vector(unsigned(pc) + 4);

      -- JALR
      when "1100111" =>
        alu_res <= std_logic_vector(unsigned(pc) + 4);

      -- BRANCH
      when "1100011" =>
        case funct3 is
          when "000" => if op_a = op_b                            then branch_taken <= '1'; end if;
          when "001" => if op_a /= op_b                           then branch_taken <= '1'; end if;
          when "100" => if signed(op_a) < signed(op_b)            then branch_taken <= '1'; end if;
          when "101" => if signed(op_a) >= signed(op_b)           then branch_taken <= '1'; end if;
          when "110" => if unsigned(op_a) < unsigned(op_b)        then branch_taken <= '1'; end if;
          when "111" => if unsigned(op_a) >= unsigned(op_b)       then branch_taken <= '1'; end if;
          when others => null;
        end case;

      -- LOAD
      -- mem_addr is the effective byte address (word-aligned sent to bus)
      -- mem_sel encodes which byte lanes are needed, shifted by byte offset
      when "0000011" =>
        mem_is_load <= '1';
        mem_addr    <= std_logic_vector(unsigned(op_a) + unsigned(imm_i));
        case funct3 is
          when "000" | "100" => -- LB / LBU: 1 byte, shifted to correct lane
            case std_logic_vector(unsigned(op_a(1 downto 0)) +
                                  unsigned(imm_i(1 downto 0))) is
              when "00"   => mem_sel <= "0001";
              when "01"   => mem_sel <= "0010";
              when "10"   => mem_sel <= "0100";
              when others => mem_sel <= "1000";
            end case;
          when "001" | "101" => -- LH / LHU: 2 bytes, shifted to correct lanes
            if (unsigned(op_a(1 downto 0)) + unsigned(imm_i(1 downto 0))) < 2 then
              mem_sel <= "0011";
            else
              mem_sel <= "1100";
            end if;
          when others => mem_sel <= "1111"; -- LW
        end case;

      -- STORE
      when "0100011" =>
        mem_is_store <= '1';
        mem_we       <= '1';
        mem_addr     <= std_logic_vector(unsigned(op_a) + unsigned(imm_s));
        case funct3 is
          when "000" => -- SB: shift byte to correct lane
            case std_logic_vector(unsigned(op_a(1 downto 0)) +
                                  unsigned(imm_s(1 downto 0))) is
              when "00" =>
                mem_sel   <= "0001";
                mem_wdata <= x"000000" & op_b(7 downto 0);
              when "01" =>
                mem_sel   <= "0010";
                mem_wdata <= x"0000" & op_b(7 downto 0) & x"00";
              when "10" =>
                mem_sel   <= "0100";
                mem_wdata <= x"00" & op_b(7 downto 0) & x"0000";
              when others =>
                mem_sel   <= "1000";
                mem_wdata <= op_b(7 downto 0) & x"000000";
            end case;
          when "001" => -- SH: shift halfword to correct lane
            if (unsigned(op_a(1 downto 0)) + unsigned(imm_s(1 downto 0))) < 2 then
              mem_sel   <= "0011";
              mem_wdata <= x"0000" & op_b(15 downto 0);
            else
              mem_sel   <= "1100";
              mem_wdata <= op_b(15 downto 0) & x"0000";
            end if;
          when others => -- SW
            mem_sel   <= "1111";
            mem_wdata <= op_b;
        end case;

      -- OP-IMM
      when "0010011" =>
        case funct3 is
          when "000" => res := std_logic_vector(signed(op_a) + signed(imm_i));
          when "010" =>
            if signed(op_a) < signed(imm_i) then res := x"00000001";
            else res := x"00000000"; end if;
          when "011" =>
            if unsigned(op_a) < unsigned(imm_i) then res := x"00000001";
            else res := x"00000000"; end if;
          when "100" => res := op_a xor imm_i;
          when "110" => res := op_a or  imm_i;
          when "111" => res := op_a and imm_i;
          when "001" =>
            res := std_logic_vector(shift_left(unsigned(op_a),
                     to_integer(unsigned(to_01(imm_i(4 downto 0), '0')))));
          when "101" =>
            if funct7(5) = '1' then res := sra32(op_a, imm_i(4 downto 0));
            else res := std_logic_vector(shift_right(unsigned(op_a),
                          to_integer(unsigned(to_01(imm_i(4 downto 0), '0'))))); end if;
          when others => null;
        end case;
        alu_res <= res;

      -- OP
      when "0110011" =>
        case funct3 is
          when "000" =>
            if funct7(5) = '1' then res := std_logic_vector(signed(op_a) - signed(op_b));
            else res := std_logic_vector(signed(op_a) + signed(op_b)); end if;
          when "001" =>
            res := std_logic_vector(shift_left(unsigned(op_a),
                     to_integer(unsigned(to_01(shamt, '0')))));
          when "010" =>
            if signed(op_a) < signed(op_b) then res := x"00000001";
            else res := x"00000000"; end if;
          when "011" =>
            if unsigned(op_a) < unsigned(op_b) then res := x"00000001";
            else res := x"00000000"; end if;
          when "100" => res := op_a xor op_b;
          when "101" =>
            if funct7(5) = '1' then res := sra32(op_a, shamt);
            else res := std_logic_vector(shift_right(unsigned(op_a),
                          to_integer(unsigned(to_01(shamt, '0'))))); end if;
          when "110" => res := op_a or  op_b;
          when "111" => res := op_a and op_b;
          when others => null;
        end case;
        alu_res <= res;

      -- FENCE
      when "0001111" =>
        null;

      -- SYSTEM (CSR + ECALL/EBREAK/MRET)
      when "1110011" =>
        if funct3 = "000" then
          -- funct12 in instr[31:20]
          if instr(31 downto 20) = x"000" then
            -- ECALL
            take_trap  <= '1';
            trap_cause <= x"0000000B"; -- ecall from M-mode
          elsif instr(31 downto 20) = x"001" then
            -- EBREAK
            take_trap  <= '1';
            trap_cause <= x"00000003";
          elsif instr(31 downto 20) = x"302" then
            -- MRET
            take_mret <= '1';
          end if;
        else
          -- CSR instructions
          is_csr  <= '1';
          -- rd gets old CSR value
          alu_res <= csr_rdata;
          -- compute write value
          case funct3 is
            when "001" => wdata := op_a;               -- CSRRW
            when "010" => wdata := csr_rdata or  op_a; -- CSRRS
            when "011" => wdata := csr_rdata and (not op_a); -- CSRRC
            when "101" => wdata := imm_z;              -- CSRRWI
            when "110" => wdata := csr_rdata or  imm_z; -- CSRRSI
            when "111" => wdata := csr_rdata and (not imm_z); -- CSRRCI
            when others => wdata := csr_rdata;
          end case;
          mem_wdata <= wdata; -- reuse mem_wdata to carry CSR write value
        end if;

      -- Illegal
      when others =>
        take_trap  <= '1';
        trap_cause <= x"00000002";
    end case;
  end process alu_proc;

  -- --------------------------------------------------------------------------
  -- PC next
  -- --------------------------------------------------------------------------
  pc_next_proc : process(opcode, pc, imm_b, imm_j, imm_i, op_a, branch_taken)
  begin
    case opcode is
      when "1101111" =>
        pc_next <= std_logic_vector(unsigned(pc) + unsigned(imm_j));
      when "1100111" =>
        pc_next <= std_logic_vector(
                    (unsigned(op_a) + unsigned(imm_i)) and x"FFFFFFFE");
      when "1100011" =>
        if branch_taken = '1' then
          pc_next <= std_logic_vector(unsigned(pc) + unsigned(imm_b));
        else
          pc_next <= std_logic_vector(unsigned(pc) + 4);
        end if;
      when others =>
        pc_next <= std_logic_vector(unsigned(pc) + 4);
    end case;
  end process pc_next_proc;

  -- --------------------------------------------------------------------------
  -- Load data decode
  -- mem_addr holds the original byte address; bus returns word at word-aligned
  -- address with data in the correct byte lanes. Extract from correct lanes.
  -- --------------------------------------------------------------------------
  load_decode : process(funct3, mem_addr, xbus_dat_i)
    variable byte_off : integer;
    variable half_off : integer;
    variable raw      : std_logic_vector(31 downto 0);
  begin
    raw      := std_logic_vector(xbus_dat_i);
    byte_off := to_integer(unsigned(to_01(mem_addr(1 downto 0), '0')));
    half_off := to_integer(unsigned(to_01(mem_addr(1 downto 1), '0')));
    mem_rdata <= (others => '0');
    case funct3 is
      when "000" => -- LB: sign-extend byte from correct lane
        case byte_off is
          when 0    => mem_rdata <= sign_ext(raw(7  downto  0), 32);
          when 1    => mem_rdata <= sign_ext(raw(15 downto  8), 32);
          when 2    => mem_rdata <= sign_ext(raw(23 downto 16), 32);
          when 3    => mem_rdata <= sign_ext(raw(31 downto 24), 32);
          when others => null;
        end case;
      when "001" => -- LH: sign-extend halfword from correct lanes
        if half_off = 0 then
          mem_rdata <= sign_ext(raw(15 downto  0), 32);
        else
          mem_rdata <= sign_ext(raw(31 downto 16), 32);
        end if;
      when "010" => -- LW
        mem_rdata <= raw;
      when "100" => -- LBU: zero-extend byte from correct lane
        case byte_off is
          when 0    => mem_rdata <= x"000000" & raw(7  downto  0);
          when 1    => mem_rdata <= x"000000" & raw(15 downto  8);
          when 2    => mem_rdata <= x"000000" & raw(23 downto 16);
          when 3    => mem_rdata <= x"000000" & raw(31 downto 24);
          when others => null;
        end case;
      when "101" => -- LHU: zero-extend halfword from correct lanes
        if half_off = 0 then
          mem_rdata <= x"0000" & raw(15 downto  0);
        else
          mem_rdata <= x"0000" & raw(31 downto 16);
        end if;
      when others => mem_rdata <= raw;
    end case;
  end process load_decode;

  -- --------------------------------------------------------------------------
  -- Wishbone drive
  -- --------------------------------------------------------------------------
  xbus_cyc_o <= wb_cyc;
  xbus_stb_o <= wb_stb;
  xbus_we_o  <= wb_we;
  xbus_adr_o <= wb_adr;
  xbus_dat_o <= wb_dato;
  xbus_sel_o <= wb_sel;

  -- --------------------------------------------------------------------------
  -- CSR write helper procedure (called from seq_proc)
  -- --------------------------------------------------------------------------

  -- --------------------------------------------------------------------------
  -- Sequential FSM
  -- --------------------------------------------------------------------------
  seq_proc : process(clk_i, rstn_i)
    variable rd_idx   : integer;
    variable mip_new  : std_logic_vector(31 downto 0);
    variable csr_wval : std_logic_vector(31 downto 0);

    -- Write a CSR by address
    procedure csr_write(addr : std_logic_vector(11 downto 0);
                        val  : std_logic_vector(31 downto 0)) is
    begin
      case addr is
        when CSR_MSTATUS  => reg_mstatus  <= val;
        when CSR_MIE      => reg_mie      <= val;
        when CSR_MTVEC    => reg_mtvec    <= val;
        when CSR_MSCRATCH => reg_mscratch <= val;
        when CSR_MEPC     => reg_mepc     <= val;
        when CSR_MCAUSE   => reg_mcause   <= val;
        when CSR_MTVAL    => reg_mtval    <= val;
        when others       => null; -- read-only or unimplemented
      end case;
    end procedure;

  begin
    if rstn_i = '0' then
      pc           <= RESET_VECTOR;
      state        <= S_FETCH;
      instr        <= (others => '0');
      rf           <= (others => (others => '0'));
      wb_cyc       <= '0';
      wb_stb       <= '0';
      wb_we        <= '0';
      wb_adr       <= (others => '0');
      wb_dato      <= (others => '0');
      wb_sel       <= (others => '0');
      reg_mstatus  <= (others => '0');
      reg_mie      <= (others => '0');
      reg_mtvec    <= (others => '0');
      reg_mscratch <= (others => '0');
      reg_mepc     <= (others => '0');
      reg_mcause   <= (others => '0');
      reg_mtval    <= (others => '0');
      reg_mip      <= (others => '0');
      dbg_valid    <= '0';
      dbg_pc       <= (others => '0');
      dbg_instr    <= (others => '0');
      dbg_rd_we    <= '0';
      dbg_rd       <= (others => '0');
      dbg_wdata    <= (others => '0');

    elsif rising_edge(clk_i) then

      -- Debug: default no-commit this cycle (pulse)
      dbg_valid <= '0';
      dbg_rd_we <= '0';

      -- Update mip from interrupt inputs
      mip_new     := reg_mip;
      mip_new(3)  := irq_msi_i;
      mip_new(7)  := irq_mti_i;
      mip_new(11) := irq_mei_i;
      reg_mip     <= mip_new;

      case state is

        -- --------------------------------------------------------------------
        when S_FETCH =>
          wb_cyc <= '1';
          wb_stb <= '1';
          wb_we  <= '0';
          wb_adr <= pc;
          wb_sel <= "1111";
          state  <= S_FETCH_WAIT;

        -- --------------------------------------------------------------------
        when S_FETCH_WAIT =>
          if xbus_err_i = '1' then
            reg_mepc   <= pc;
            reg_mcause <= x"00000001"; -- instruction access fault
            reg_mtval  <= pc;
            wb_cyc <= '0'; wb_stb <= '0';
            state  <= S_TRAP;
          elsif xbus_ack_i = '1' then
            instr  <= std_logic_vector(xbus_dat_i);
            wb_cyc <= '0'; wb_stb <= '0';
            state  <= S_EXEC;
          end if;

        -- --------------------------------------------------------------------
        when S_EXEC =>
          rd_idx := to_integer(unsigned(to_01(rd, '0')));

          if take_trap = '1' then
            reg_mepc   <= pc;
            reg_mcause <= trap_cause;
            reg_mtval  <= trap_val;
            state      <= S_TRAP;

          elsif take_mret = '1' then
            state <= S_MRET;

          elsif is_csr = '1' then
            -- Write CSR (mem_wdata carries the write value from alu_proc)
            csr_wval := mem_wdata;
            csr_write(csr_adr, csr_wval);
            -- Write rd with old CSR value
            if rd_idx /= 0 then
              rf(rd_idx) <= alu_res;
              dbg_rd_we  <= '1';
              dbg_rd     <= rd;
              dbg_wdata  <= alu_res;
            end if;
            dbg_valid <= '1';
            dbg_pc    <= pc;
            dbg_instr <= instr;
            pc    <= pc_next;
            state <= S_FETCH;

          elsif mem_is_load = '1' or mem_is_store = '1' then
            wb_cyc  <= '1';
            wb_stb  <= '1';
            wb_we   <= mem_we;
            wb_adr  <= mem_addr;
            wb_dato <= mem_wdata;
            wb_sel  <= mem_sel;
            state   <= S_MEM_WAIT;

          else
            -- ALU / branch / jump
            if rd_idx /= 0 then
              case opcode is
                when "0110111" | "0010111" | "1101111" | "1100111" |
                     "0010011" | "0110011" =>
                  rf(rd_idx) <= alu_res;
                  dbg_rd_we  <= '1';
                  dbg_rd     <= rd;
                  dbg_wdata  <= alu_res;
                when others => null;
              end case;
            end if;
            dbg_valid <= '1';
            dbg_pc    <= pc;
            dbg_instr <= instr;
            pc    <= pc_next;
            state <= S_FETCH;
          end if;

        -- --------------------------------------------------------------------
        when S_MEM_WAIT =>
          if xbus_err_i = '1' then
            reg_mepc <= pc;
            if mem_is_load = '1' then
              reg_mcause <= x"00000005"; -- load access fault
              reg_mtval  <= mem_addr;
            else
              reg_mcause <= x"00000007"; -- store access fault
              reg_mtval  <= mem_addr;
            end if;
            wb_cyc <= '0'; wb_stb <= '0';
            state  <= S_TRAP;
          elsif xbus_ack_i = '1' then
            wb_cyc <= '0'; wb_stb <= '0';
            rd_idx := to_integer(unsigned(to_01(rd, '0')));
            if mem_is_load = '1' and rd_idx /= 0 then
              rf(rd_idx) <= mem_rdata;
              dbg_rd_we  <= '1';
              dbg_rd     <= rd;
              dbg_wdata  <= mem_rdata;
            end if;
            dbg_valid <= '1';
            dbg_pc    <= pc;
            dbg_instr <= instr;
            pc    <= pc_next;
            state <= S_FETCH;
          end if;

        -- --------------------------------------------------------------------
        when S_TRAP =>
          -- Disable MIE, save MIE->MPIE, jump to mtvec
          reg_mstatus(7) <= reg_mstatus(3); -- MPIE = MIE
          reg_mstatus(3) <= '0';            -- MIE  = 0
          pc    <= reg_mtvec(31 downto 2) & "00";
          state <= S_FETCH;

        -- --------------------------------------------------------------------
        when S_MRET =>
          -- Restore MIE from MPIE
          reg_mstatus(3) <= reg_mstatus(7); -- MIE  = MPIE
          reg_mstatus(7) <= '1';            -- MPIE = 1
          pc    <= reg_mepc;
          state <= S_FETCH;

        -- --------------------------------------------------------------------
        when others =>
          state <= S_FETCH;

      end case;
    end if;
  end process seq_proc;

  -- Debug port drive (concurrent)
  dbg_valid_o <= dbg_valid;
  dbg_pc_o    <= dbg_pc;
  dbg_instr_o <= dbg_instr;
  dbg_rd_we_o <= dbg_rd_we;
  dbg_rd_o    <= dbg_rd;
  dbg_wdata_o <= dbg_wdata;

end architecture rtl;
