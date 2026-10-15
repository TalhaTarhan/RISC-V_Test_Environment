-- =============================================================================
-- rv32_dut.vhd
-- RV32I core (38-instruction subset) for RISCOF testing
-- Standard : VHDL-93
-- Bus      : Wishbone B4 classic
-- Pipeline : Single-cycle with bus-stall handshake
-- Reset    : Asynchronous, active-low; PC resets to 0x00000000
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
entity neorv32_top is
  port (
    -- Global
    clk_i          : in  std_logic;
    rstn_i         : in  std_logic;
    -- Wishbone master
    xbus_adr_o     : out std_logic_vector(31 downto 0);
    xbus_dat_o     : out std_logic_vector(31 downto 0);
    xbus_we_o      : out std_logic;
    xbus_sel_o     : out std_logic_vector(3 downto 0);
    xbus_stb_o     : out std_logic;
    xbus_cyc_o     : out std_logic;
    xbus_dat_i     : in  std_logic_vector(31 downto 0) := (others => '0');
    xbus_ack_i     : in  std_logic := '0';
    xbus_err_i     : in  std_logic := '0';
    -- Interrupts
    irq_msi_i      : in  std_logic := '0';
    irq_mti_i      : in  std_logic := '0';
    irq_mei_i      : in  std_logic := '0'
  );
end entity neorv32_top;

-- =============================================================================
architecture rtl of neorv32_top is

  -- --------------------------------------------------------------------------
  -- Constants
  -- --------------------------------------------------------------------------
  constant RESET_VECTOR : std_logic_vector(31 downto 0) := x"80000000";
  constant XOR_ALU  : std_logic_vector(2 downto 0) := "100";

  -- --------------------------------------------------------------------------
  -- Register file
  -- --------------------------------------------------------------------------
  type regfile_t is array (0 to 31) of std_logic_vector(31 downto 0);
  signal rf : regfile_t := (others => (others => '0'));

  -- --------------------------------------------------------------------------
  -- CSRs
  -- --------------------------------------------------------------------------
  signal csr_mstatus  : std_logic_vector(31 downto 0) := (others => '0');
  signal csr_mie      : std_logic_vector(31 downto 0) := (others => '0');
  signal csr_mtvec    : std_logic_vector(31 downto 0) := (others => '0');
  signal csr_mscratch : std_logic_vector(31 downto 0) := (others => '0');
  signal csr_mepc     : std_logic_vector(31 downto 0) := (others => '0');
  signal csr_mcause   : std_logic_vector(31 downto 0) := (others => '0');
  signal csr_mip      : std_logic_vector(31 downto 0) := (others => '0');

  -- --------------------------------------------------------------------------
  -- PC
  -- --------------------------------------------------------------------------
  signal pc      : std_logic_vector(31 downto 0) := RESET_VECTOR;
  signal pc_next : std_logic_vector(31 downto 0);

  -- --------------------------------------------------------------------------
  -- FSM
  -- --------------------------------------------------------------------------
  type state_t is (S_FETCH, S_FETCH_WAIT, S_EXEC, S_MEM, S_MEM_WAIT, S_TRAP);
  signal state      : state_t := S_FETCH;
  signal state_next : state_t;

  -- --------------------------------------------------------------------------
  -- Instruction register
  -- --------------------------------------------------------------------------
  signal instr      : std_logic_vector(31 downto 0) := (others => '0');

  -- --------------------------------------------------------------------------
  -- Decode signals
  -- --------------------------------------------------------------------------
  signal opcode   : std_logic_vector(6 downto 0);
  signal rd       : std_logic_vector(4 downto 0);
  signal rs1      : std_logic_vector(4 downto 0);
  signal rs2      : std_logic_vector(4 downto 0);
  signal funct3   : std_logic_vector(2 downto 0);
  signal funct7   : std_logic_vector(6 downto 0);

  signal imm_i    : std_logic_vector(31 downto 0);
  signal imm_s    : std_logic_vector(31 downto 0);
  signal imm_b    : std_logic_vector(31 downto 0);
  signal imm_u    : std_logic_vector(31 downto 0);
  signal imm_j    : std_logic_vector(31 downto 0);

  -- Operands
  signal op_a     : std_logic_vector(31 downto 0);
  signal op_b     : std_logic_vector(31 downto 0);

  -- ALU result
  signal alu_res  : std_logic_vector(31 downto 0);

  -- Branch taken
  signal branch_taken : std_logic;

  -- Memory access helpers
  signal mem_addr   : std_logic_vector(31 downto 0);
  signal mem_wdata  : std_logic_vector(31 downto 0);
  signal mem_rdata  : std_logic_vector(31 downto 0);
  signal mem_we     : std_logic;
  signal mem_sel    : std_logic_vector(3 downto 0);
  signal mem_is_load  : std_logic;
  signal mem_is_store : std_logic;

  -- Wishbone internal
  signal wb_cyc   : std_logic;
  signal wb_stb   : std_logic;
  signal wb_we    : std_logic;
  signal wb_adr   : std_logic_vector(31 downto 0);
  signal wb_dato  : std_logic_vector(31 downto 0);
  signal wb_sel   : std_logic_vector(3 downto 0);

  -- Trap
  signal trap_cause : std_logic_vector(31 downto 0);
  signal take_trap  : std_logic;

  -- --------------------------------------------------------------------------
  -- Helper function: sign-extend
  -- --------------------------------------------------------------------------
  function sign_ext(v : std_logic_vector; w : integer) return std_logic_vector is
    variable r : std_logic_vector(w-1 downto 0);
  begin
    r := (others => v(v'left));
    r(v'length-1 downto 0) := v;
    return r;
  end function;

  -- --------------------------------------------------------------------------
  -- Helper: shift right arithmetic 32-bit
  -- --------------------------------------------------------------------------
  function sra32(val : std_logic_vector(31 downto 0);
                 shamt : std_logic_vector(4 downto 0))
                 return std_logic_vector is
    variable sv  : signed(31 downto 0);
    variable sh  : integer;
  begin
    sv := signed(val);
    sh := to_integer(unsigned(shamt));
    return std_logic_vector(shift_right(sv, sh));
  end function;

begin

  -- --------------------------------------------------------------------------
  -- Decode (combinational, uses registered 'instr')
  -- --------------------------------------------------------------------------
  opcode  <= instr(6 downto 0);
  rd      <= instr(11 downto 7);
  funct3  <= instr(14 downto 12);
  rs1     <= instr(19 downto 15);
  rs2     <= instr(24 downto 20);
  funct7  <= instr(31 downto 25);

  -- Immediate formats
  imm_i <= sign_ext(instr(31 downto 20), 32);

  imm_s <= sign_ext(instr(31 downto 25) & instr(11 downto 7), 32);

  imm_b <= sign_ext(instr(31) & instr(7) & instr(30 downto 25) & instr(11 downto 8) & '0', 32);

  imm_u <= instr(31 downto 12) & x"000";

  imm_j <= sign_ext(instr(31) & instr(19 downto 12) & instr(20) & instr(30 downto 21) & '0', 32);

  -- Source operands (read from register file)
  op_a <= rf(to_integer(unsigned(rs1)));
  op_b <= rf(to_integer(unsigned(rs2)));

  -- --------------------------------------------------------------------------
  -- ALU (combinational)
  -- --------------------------------------------------------------------------
  alu_proc : process(opcode, funct3, funct7, op_a, op_b, imm_i, imm_u, imm_s,
                     imm_b, imm_j, pc)
    variable shamt  : std_logic_vector(4 downto 0);
    variable sum_a  : unsigned(31 downto 0);
    variable sum_b  : unsigned(31 downto 0);
    variable res    : std_logic_vector(31 downto 0);
    variable sltu_v : std_logic;
    variable slt_v  : std_logic;
    variable st_adr : unsigned(31 downto 0);
  begin
    shamt  := op_b(4 downto 0);
    res    := (others => '0');
    branch_taken <= '0';
    mem_is_load  <= '0';
    mem_is_store <= '0';
    mem_we       <= '0';
    mem_sel      <= "0000";
    mem_addr     <= (others => '0');
    mem_wdata    <= (others => '0');
    alu_res      <= (others => '0');
    take_trap    <= '0';
    trap_cause   <= (others => '0');

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
        sum_a := unsigned(op_a);
        sum_b := unsigned(op_b);
        case funct3 is
          when "000" => -- BEQ
            if op_a = op_b then branch_taken <= '1'; end if;
          when "001" => -- BNE
            if op_a /= op_b then branch_taken <= '1'; end if;
          when "100" => -- BLT
            if signed(op_a) < signed(op_b) then branch_taken <= '1'; end if;
          when "101" => -- BGE
            if signed(op_a) >= signed(op_b) then branch_taken <= '1'; end if;
          when "110" => -- BLTU
            if sum_a < sum_b then branch_taken <= '1'; end if;
          when "111" => -- BGEU
            if sum_a >= sum_b then branch_taken <= '1'; end if;
          when others => null;
        end case;

      -- LOAD
      when "0000011" =>
        mem_is_load <= '1';
        mem_addr    <= std_logic_vector(unsigned(op_a) + unsigned(imm_i));
        case funct3 is
          when "000" | "100" => mem_sel <= "0001"; -- LB/LBU
          when "001" | "101" => mem_sel <= "0011"; -- LH/LHU
          when "010"         => mem_sel <= "1111"; -- LW
          when others        => mem_sel <= "1111";
        end case;

      -- STORE (data and byte lanes shifted according to address[1:0])
      when "0100011" =>
        st_adr       := unsigned(op_a) + unsigned(imm_s);
        mem_is_store <= '1';
        mem_we       <= '1';
        mem_addr     <= std_logic_vector(st_adr);
        case funct3 is
          when "000" => -- SB
            case st_adr(1 downto 0) is
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
          when "001" => -- SH
            if st_adr(1) = '0' then
              mem_sel   <= "0011";
              mem_wdata <= x"0000" & op_b(15 downto 0);
            else
              mem_sel   <= "1100";
              mem_wdata <= op_b(15 downto 0) & x"0000";
            end if;
          when "010" => -- SW
            mem_sel   <= "1111";
            mem_wdata <= op_b;
          when others =>
            mem_sel   <= "1111";
            mem_wdata <= op_b;
        end case;

      -- OP-IMM
      when "0010011" =>
        case funct3 is
          when "000" => -- ADDI
            res := std_logic_vector(signed(op_a) + signed(imm_i));
          when "010" => -- SLTI
            if signed(op_a) < signed(imm_i) then res := x"00000001";
            else res := x"00000000"; end if;
          when "011" => -- SLTIU
            if unsigned(op_a) < unsigned(imm_i) then res := x"00000001";
            else res := x"00000000"; end if;
          when "100" => -- XORI
            res := op_a xor imm_i;
          when "110" => -- ORI
            res := op_a or imm_i;
          when "111" => -- ANDI
            res := op_a and imm_i;
          when "001" => -- SLLI
            res := std_logic_vector(shift_left(unsigned(op_a),
                     to_integer(unsigned(imm_i(4 downto 0)))));
          when "101" => -- SRLI / SRAI
            if funct7(5) = '1' then
              res := sra32(op_a, imm_i(4 downto 0));
            else
              res := std_logic_vector(shift_right(unsigned(op_a),
                       to_integer(unsigned(imm_i(4 downto 0)))));
            end if;
          when others => null;
        end case;
        alu_res <= res;

      -- OP (register-register)
      when "0110011" =>
        case funct3 is
          when "000" => -- ADD / SUB
            if funct7(5) = '1' then
              res := std_logic_vector(signed(op_a) - signed(op_b));
            else
              res := std_logic_vector(signed(op_a) + signed(op_b));
            end if;
          when "001" => -- SLL
            res := std_logic_vector(shift_left(unsigned(op_a),
                     to_integer(unsigned(shamt))));
          when "010" => -- SLT
            if signed(op_a) < signed(op_b) then res := x"00000001";
            else res := x"00000000"; end if;
          when "011" => -- SLTU
            if unsigned(op_a) < unsigned(op_b) then res := x"00000001";
            else res := x"00000000"; end if;
          when "100" => -- XOR
            res := op_a xor op_b;
          when "101" => -- SRL / SRA
            if funct7(5) = '1' then
              res := sra32(op_a, shamt);
            else
              res := std_logic_vector(shift_right(unsigned(op_a),
                       to_integer(unsigned(shamt))));
            end if;
          when "110" => -- OR
            res := op_a or op_b;
          when "111" => -- AND
            res := op_a and op_b;
          when others => null;
        end case;
        alu_res <= res;

      -- FENCE (treat as NOP)
      when "0001111" =>
        null;

      -- Illegal / unimplemented
      when others =>
        take_trap  <= '1';
        trap_cause <= x"00000002"; -- Illegal instruction
    end case;
  end process alu_proc;

  -- --------------------------------------------------------------------------
  -- PC next (combinational)
  -- --------------------------------------------------------------------------
  pc_next_proc : process(opcode, pc, imm_b, imm_j, imm_i, op_a, branch_taken)
  begin
    case opcode is
      when "1101111" => -- JAL
        pc_next <= std_logic_vector(unsigned(pc) + unsigned(imm_j));
      when "1100111" => -- JALR
        pc_next <= std_logic_vector(
                    (unsigned(op_a) + unsigned(imm_i)) and x"FFFFFFFE");
      when "1100011" => -- BRANCH
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
  -- --------------------------------------------------------------------------
  load_decode : process(funct3, mem_addr, xbus_dat_i)
    variable byte_off : integer;
    variable half_off : integer;
    variable raw      : std_logic_vector(31 downto 0);
  begin
    raw      := std_logic_vector(xbus_dat_i);
    byte_off := to_integer(unsigned(mem_addr(1 downto 0)));
    half_off := to_integer(unsigned(mem_addr(1 downto 1)));
    mem_rdata <= (others => '0');
    case funct3 is
      when "000" => -- LB
        case byte_off is
          when 0 => mem_rdata <= sign_ext(raw(7  downto  0), 32);
          when 1 => mem_rdata <= sign_ext(raw(15 downto  8), 32);
          when 2 => mem_rdata <= sign_ext(raw(23 downto 16), 32);
          when 3 => mem_rdata <= sign_ext(raw(31 downto 24), 32);
          when others => null;
        end case;
      when "001" => -- LH
        if half_off = 0 then
          mem_rdata <= sign_ext(raw(15 downto 0), 32);
        else
          mem_rdata <= sign_ext(raw(31 downto 16), 32);
        end if;
      when "010" => -- LW
        mem_rdata <= raw;
      when "100" => -- LBU
        case byte_off is
          when 0 => mem_rdata <= x"000000" & raw(7  downto  0);
          when 1 => mem_rdata <= x"000000" & raw(15 downto  8);
          when 2 => mem_rdata <= x"000000" & raw(23 downto 16);
          when 3 => mem_rdata <= x"000000" & raw(31 downto 24);
          when others => null;
        end case;
      when "101" => -- LHU
        if half_off = 0 then
          mem_rdata <= x"0000" & raw(15 downto 0);
        else
          mem_rdata <= x"0000" & raw(31 downto 16);
        end if;
      when others =>
        mem_rdata <= raw;
    end case;
  end process load_decode;

  -- --------------------------------------------------------------------------
  -- Wishbone drive (combinational from FSM)
  -- --------------------------------------------------------------------------
  xbus_cyc_o <= wb_cyc;
  xbus_stb_o <= wb_stb;
  xbus_we_o  <= wb_we;
  xbus_adr_o <= wb_adr;
  xbus_dat_o <= wb_dato;
  xbus_sel_o <= wb_sel;

  -- --------------------------------------------------------------------------
  -- Sequential FSM
  -- --------------------------------------------------------------------------
  seq_proc : process(clk_i, rstn_i)
    variable rd_idx  : integer;
    variable mip_new : std_logic_vector(31 downto 0);
  begin
    if rstn_i = '0' then
      pc        <= RESET_VECTOR;
      state     <= S_FETCH;
      instr     <= (others => '0');
      rf        <= (others => (others => '0'));
      wb_cyc    <= '0';
      wb_stb    <= '0';
      wb_we     <= '0';
      wb_adr    <= (others => '0');
      wb_dato   <= (others => '0');
      wb_sel    <= (others => '0');
      csr_mstatus  <= (others => '0');
      csr_mie      <= (others => '0');
      csr_mtvec    <= (others => '0');
      csr_mscratch <= (others => '0');
      csr_mepc     <= (others => '0');
      csr_mcause   <= (others => '0');
      csr_mip      <= (others => '0');

    elsif rising_edge(clk_i) then

      -- Update mip from interrupt lines
      mip_new := csr_mip;
      mip_new(3) := irq_msi_i;
      mip_new(7) := irq_mti_i;
      mip_new(11):= irq_mei_i;
      csr_mip <= mip_new;

      case state is

        -- --------------------------------------------------------------------
        when S_FETCH =>
          -- Initiate instruction fetch via Wishbone
          wb_cyc <= '1';
          wb_stb <= '1';
          wb_we  <= '0';
          wb_adr <= pc;
          wb_sel <= "1111";
          state  <= S_FETCH_WAIT;

        -- --------------------------------------------------------------------
        when S_FETCH_WAIT =>
          if xbus_err_i = '1' then
            -- Instruction access fault
            csr_mepc   <= pc;
            csr_mcause <= x"00000001";
            wb_cyc <= '0';
            wb_stb <= '0';
            state  <= S_TRAP;
          elsif xbus_ack_i = '1' then
            instr  <= std_logic_vector(xbus_dat_i);
            wb_cyc <= '0';
            wb_stb <= '0';
            state  <= S_EXEC;
          end if;

        -- --------------------------------------------------------------------
        when S_EXEC =>
          rd_idx := to_integer(unsigned(rd));

          if take_trap = '1' then
            csr_mepc   <= pc;
            csr_mcause <= trap_cause;
            state      <= S_TRAP;

          elsif mem_is_load = '1' or mem_is_store = '1' then
            -- Initiate data memory access
            wb_cyc  <= '1';
            wb_stb  <= '1';
            wb_we   <= mem_we;
            wb_adr  <= mem_addr;
            wb_dato <= mem_wdata;
            wb_sel  <= mem_sel;
            state   <= S_MEM_WAIT;

          else
            -- Non-memory instruction: write result, advance PC
            if rd_idx /= 0 then
              case opcode is
                when "0110111" | "0010111" | "1101111" | "1100111" |
                     "0010011" | "0110011" =>
                  rf(rd_idx) <= alu_res;
                when others => null;
              end case;
            end if;
            pc    <= pc_next;
            state <= S_FETCH;
          end if;

        -- --------------------------------------------------------------------
        when S_MEM_WAIT =>
          if xbus_err_i = '1' then
            csr_mepc   <= pc;
            if mem_is_load = '1' then
              csr_mcause <= x"00000005"; -- Load access fault
            else
              csr_mcause <= x"00000007"; -- Store access fault
            end if;
            wb_cyc <= '0';
            wb_stb <= '0';
            state  <= S_TRAP;
          elsif xbus_ack_i = '1' then
            wb_cyc <= '0';
            wb_stb <= '0';
            rd_idx := to_integer(unsigned(rd));
            if mem_is_load = '1' and rd_idx /= 0 then
              rf(rd_idx) <= mem_rdata;
            end if;
            pc    <= pc_next;
            state <= S_FETCH;
          end if;

        -- --------------------------------------------------------------------
        when S_MEM =>
          -- Unused state kept for future pipeline extension
          state <= S_FETCH;

        -- --------------------------------------------------------------------
        when S_TRAP =>
          -- Jump to mtvec (direct mode, bits[1:0] = 00)
          pc    <= csr_mtvec(31 downto 2) & "00";
          state <= S_FETCH;

        -- --------------------------------------------------------------------
        when others =>
          state <= S_FETCH;

      end case;
    end if;
  end process seq_proc;

end architecture rtl;
