--------------------------------------------------------------------------------
-- Title       : I2C Slave Controller
-- Project     : I2C Slave Implementation
-- File        : i2c_slave.vhd
-- Author      : Sicris Rey Embay
-- Created     : July 27, 2025
-- Modified    : March 23, 2026 - Delay ACK state entry to 8th SCL falling edge
-- Description : Register-based I2C slave implementation
--               Supports 7-bit addressing, repeated start, auto-increment reads
--
-- Key design: SDA output is driven combinatorially from state (not from a
-- clocked send_ack register) to eliminate ACK timing ambiguity.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_slave is
    generic (
        SLAVE_ADDR : std_logic_vector(6 downto 0) := "1010000";  -- 7-bit I2C address (0x50)
        NUM_REGS   : integer := 16                               -- Number of internal registers
    );
    port (
        -- System signals
        clk         : in  std_logic;                             -- System clock
        rst_n       : in  std_logic;                             -- Active low reset
        
        -- I2C interface
        scl         : in  std_logic;                             -- I2C clock line
        sda_in      : in  std_logic;                             -- I2C data line input
        sda_out     : out std_logic;                             -- I2C data line output
        sda_oe      : out std_logic;                             -- I2C data line output enable
        
        -- Register interface
        reg_addr    : out std_logic_vector(7 downto 0);         -- Register address
        reg_data_out: out std_logic_vector(7 downto 0);         -- Data to write to register
        reg_data_in : in  std_logic_vector(7 downto 0);         -- Data read from register
        reg_write   : out std_logic;                             -- Register write enable
        reg_read    : out std_logic;                             -- Register read enable
        
        -- Status signals
        i2c_active  : out std_logic;                             -- I2C transaction active
        error       : out std_logic                              -- Error flag
    );
end entity i2c_slave;

architecture behavioral of i2c_slave is

    type i2c_state_type is (
        IDLE,
        START_DETECTED,
        ADDR_RECEIVE,
        ADDR_ACK,
        DATA_RECEIVE,
        DATA_ACK,
        DATA_SEND,
        DATA_SEND_LOAD,   -- one-cycle latch of new register data after burst ACK
        DATA_WAIT_ACK,
        STOP_DETECTED
    );

    signal state            : i2c_state_type := IDLE;

    -- 3-stage synchronizers
    signal scl_sync         : std_logic_vector(2 downto 0) := (others => '1');
    signal sda_sync         : std_logic_vector(2 downto 0) := (others => '1');

    -- Edge / condition detection (combinatorial)
    signal scl_falling      : std_logic;
    signal scl_rising       : std_logic;
    signal sda_falling      : std_logic;
    signal sda_rising       : std_logic;
    signal start_cond       : std_logic;
    signal stop_cond        : std_logic;

    -- Receive shift register
    signal shift_reg        : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_count        : unsigned(2 downto 0) := (others => '0');

    -- Address / direction
    signal addr_match       : std_logic := '0';
    signal rw_bit           : std_logic := '0';  -- 0=write, 1=read

    -- Register pointer and write data buffer
    signal current_reg_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal data_buffer      : std_logic_vector(7 downto 0) := (others => '0');

    -- Transmit shift register (used in DATA_SEND)
    signal tx_shift_reg     : std_logic_vector(7 downto 0) := (others => '0');

    -- Set when 9th SCL rising edge is seen in ADDR_ACK / DATA_ACK,
    -- so exit happens only on the true 9th falling edge.
    signal ack_clk_seen     : std_logic := '0';

    -- '0' = next DATA_RECEIVE byte is the register pointer,
    -- '1' = register pointer already set; subsequent bytes are write data.
    signal reg_ptr_set      : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Synchronizers
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            scl_sync <= (others => '1');
            sda_sync <= (others => '1');
        elsif rising_edge(clk) then
            scl_sync <= scl_sync(1 downto 0) & scl;
            sda_sync <= sda_sync(1 downto 0) & sda_in;
        end if;
    end process;

    scl_falling <= scl_sync(2) and not scl_sync(1);
    scl_rising  <= not scl_sync(2) and scl_sync(1);
    sda_falling <= sda_sync(2) and not sda_sync(1);
    sda_rising  <= not sda_sync(2) and sda_sync(1);

    start_cond  <= sda_falling when scl_sync(1) = '1' else '0';
    stop_cond   <= sda_rising  when scl_sync(1) = '1' else '0';

    ---------------------------------------------------------------------------
    -- State machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state            <= IDLE;
            shift_reg        <= (others => '0');
            bit_count        <= (others => '0');
            addr_match       <= '0';
            rw_bit           <= '0';
            current_reg_addr <= (others => '0');
            data_buffer      <= (others => '0');
            tx_shift_reg     <= (others => '0');
            ack_clk_seen     <= '0';
            reg_ptr_set      <= '0';

        elsif rising_edge(clk) then

            case state is

                when IDLE =>
                    shift_reg    <= (others => '0');
                    bit_count    <= (others => '0');
                    addr_match   <= '0';
                    ack_clk_seen <= '0';
                    reg_ptr_set  <= '0';
                    if start_cond = '1' then
                        state <= START_DETECTED;
                    end if;

                when START_DETECTED =>
                    shift_reg <= (others => '0');
                    bit_count <= (others => '0');
                    if scl_falling = '1' then
                        state <= ADDR_RECEIVE;
                    end if;

                -- Receive 7-bit address + R/W bit (8 SCL rising edges)
                -- Transition to ADDR_ACK only on the 8th SCL *falling* edge so
                -- the slave never pulls SDA low while SCL is still high (which
                -- would be misread as a START condition by the master).
                -- ack_clk_seen is reused here as "all 8 bits sampled" flag.
                when ADDR_RECEIVE =>
                    if scl_rising = '1' then
                        shift_reg <= shift_reg(6 downto 0) & sda_sync(1);
                        bit_count <= bit_count + 1;

                        if bit_count = 7 then
                            -- shift_reg(6:0) = A6..A0, sda_sync(1) = R/W
                            if shift_reg(6 downto 0) = SLAVE_ADDR then
                                addr_match <= '1';
                                rw_bit     <= sda_sync(1);
                            else
                                addr_match <= '0';
                            end if;
                            ack_clk_seen <= '1';  -- mark: wait for 8th falling
                        end if;
                    end if;
                    if scl_falling = '1' and ack_clk_seen = '1' then
                        ack_clk_seen <= '0';
                        state        <= ADDR_ACK;
                    end if;

                -- Hold SDA low (ACK) or high (NACK) across 9th SCL clock
                -- Output is driven by the combinatorial process below, not here.
                when ADDR_ACK =>
                    if scl_rising = '1' then
                        ack_clk_seen <= '1';
                    end if;
                    if scl_falling = '1' and ack_clk_seen = '1' then
                        ack_clk_seen <= '0';
                        bit_count    <= (others => '0');
                        shift_reg    <= (others => '0');
                        if addr_match = '1' then
                            if rw_bit = '0' then
                                state <= DATA_RECEIVE;
                            else
                                data_buffer  <= reg_data_in;
                                tx_shift_reg <= reg_data_in;
                                state        <= DATA_SEND;
                            end if;
                        else
                            state <= IDLE;
                        end if;
                    end if;

                -- Receive a byte: register pointer (first) or write data
                -- Transition to DATA_ACK on the 8th SCL *falling* edge for the
                -- same reason as ADDR_RECEIVE (avoid SDA-low while SCL-high).
                when DATA_RECEIVE =>
                    if scl_rising = '1' then
                        shift_reg <= shift_reg(6 downto 0) & sda_sync(1);
                        bit_count <= bit_count + 1;

                        if bit_count = 7 then
                            if reg_ptr_set = '0' then
                                current_reg_addr <= shift_reg(6 downto 0) & sda_sync(1);
                            else
                                data_buffer <= shift_reg(6 downto 0) & sda_sync(1);
                            end if;
                            ack_clk_seen <= '1';  -- mark: wait for 8th falling
                        end if;
                    end if;
                    if scl_falling = '1' and ack_clk_seen = '1' then
                        ack_clk_seen <= '0';
                        state        <= DATA_ACK;
                    end if;

                -- ACK the received byte; increment address for data bytes
                when DATA_ACK =>
                    if scl_rising = '1' then
                        ack_clk_seen <= '1';
                    end if;
                    if scl_falling = '1' and ack_clk_seen = '1' then
                        ack_clk_seen <= '0';
                        bit_count    <= (others => '0');
                        shift_reg    <= (others => '0');
                        if reg_ptr_set = '0' then
                            reg_ptr_set <= '1';
                        else
                            current_reg_addr <= std_logic_vector(
                                unsigned(current_reg_addr) + 1);
                        end if;
                        state <= DATA_RECEIVE;
                    end if;

                -- Shift out tx_shift_reg MSB-first on each SCL falling edge.
                -- tx_shift_reg is pre-loaded before entering this state so we
                -- always shift; no bit-0 reload needed.
                when DATA_SEND =>
                    if scl_falling = '1' then
                        tx_shift_reg <= tx_shift_reg(6 downto 0) & '0';
                        bit_count    <= bit_count + 1;
                        if bit_count = 7 then
                            state <= DATA_WAIT_ACK;
                        end if;
                    end if;

                -- Sample master ACK/NACK. When master ACKs, latch the new
                -- address immediately (on the rising edge) but defer the
                -- transition to DATA_SEND_LOAD until the ACK SCL FALLS.
                -- This matches the timing of ADDR_ACK → DATA_SEND and ensures
                -- DATA_SEND is entered with SCL already low, so no spurious
                -- shift occurs on the ACK falling edge.
                when DATA_WAIT_ACK =>
                    if scl_rising = '1' and ack_clk_seen = '0' then
                        if sda_sync(1) = '0' then   -- ACK → queue burst byte
                            ack_clk_seen     <= '1';
                            current_reg_addr <= std_logic_vector(
                                unsigned(current_reg_addr) + 1);
                        else                         -- NACK → end
                            state <= IDLE;
                        end if;
                    end if;
                    if scl_falling = '1' and ack_clk_seen = '1' then
                        ack_clk_seen <= '0';
                        bit_count    <= (others => '0');
                        state        <= DATA_SEND_LOAD;
                    end if;

                -- One-cycle staging state: current_reg_addr has been
                -- incremented; reg_data_in already reflects the new address
                -- (async combinatorial read in register_file). Load tx_shift_reg
                -- and go directly to DATA_SEND.
                when DATA_SEND_LOAD =>
                    tx_shift_reg <= reg_data_in;
                    state        <= DATA_SEND;

                when STOP_DETECTED =>
                    state <= IDLE;

                when others =>
                    state <= IDLE;

            end case;

            -- Global STOP: return to IDLE, preserve current_reg_addr.
            -- Excluded during slave-drives-SDA phases (ADDR_ACK, DATA_ACK,
            -- DATA_SEND, DATA_SEND_LOAD) to prevent the slave's own SDA
            -- pull-low from being interpreted as a START/STOP condition.
            if stop_cond = '1' and
               state /= ADDR_ACK      and
               state /= DATA_ACK      and
               state /= DATA_SEND     and
               state /= DATA_SEND_LOAD then
                state        <= IDLE;
                ack_clk_seen <= '0';
                reg_ptr_set  <= '0';
            end if;

            -- Global repeated START: restart address phase, preserve current_reg_addr.
            if start_cond = '1' and state /= IDLE and
               state /= ADDR_ACK      and
               state /= DATA_ACK      and
               state /= DATA_SEND     and
               state /= DATA_SEND_LOAD then
                state        <= START_DETECTED;
                shift_reg    <= (others => '0');
                bit_count    <= (others => '0');
                addr_match   <= '0';
                ack_clk_seen <= '0';
                reg_ptr_set  <= '0';
            end if;

        end if;
    end process;

    ---------------------------------------------------------------------------
    -- SDA output — combinatorial from state.
    -- Driving from state (not from a clocked send_ack register) means the
    -- ACK is asserted exactly while in ADDR_ACK / DATA_ACK, with no
    -- clocked latency or risk of the signal going stale.
    --
    --  ADDR_ACK + addr_match='1' → SDA=0 (ACK)
    --  ADDR_ACK + addr_match='0' → SDA=1 (NACK, OE released)
    --  DATA_ACK                  → SDA=0 (ACK)
    --  DATA_SEND                 → drive tx_shift_reg(7)
    --  all others                → release SDA
    ---------------------------------------------------------------------------
    process(state, addr_match, tx_shift_reg)
    begin
        case state is
            when ADDR_ACK =>
                if addr_match = '1' then
                    sda_out <= '0';
                    sda_oe  <= '1';
                else
                    sda_out <= '1';
                    sda_oe  <= '0';
                end if;

            when DATA_ACK =>
                sda_out <= '0';
                sda_oe  <= '1';

            when DATA_SEND =>
                sda_out <= tx_shift_reg(7);
                sda_oe  <= '1';

            when others =>
                sda_out <= '1';
                sda_oe  <= '0';
        end case;
    end process;

    ---------------------------------------------------------------------------
    -- Register bus
    ---------------------------------------------------------------------------
    reg_addr     <= current_reg_addr;
    reg_data_out <= data_buffer;

    -- Write strobe: pulse for one clock on the 9th SCL rising edge of DATA_ACK
    -- when reg_ptr_set='1' (i.e. this is a data byte, not the pointer byte).
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            reg_write <= '0';
        elsif rising_edge(clk) then
            reg_write <= '0';
            if state = DATA_ACK and scl_rising = '1' and reg_ptr_set = '1' then
                reg_write <= '1';
            end if;
        end if;
    end process;

    -- reg_read: kept for interface compatibility; register_file now uses
    -- combinatorial (async) read so this strobe has no functional effect.
    -- Driven high when transitioning into a read to allow future pipelined
    -- register-file variants to be dropped in without changing this file.
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            reg_read <= '0';
        elsif rising_edge(clk) then
            reg_read <= '0';
            if (state = ADDR_ACK and scl_rising = '1' and
                addr_match = '1' and rw_bit = '1') or
               (state = DATA_WAIT_ACK and scl_rising = '1' and
                sda_sync(1) = '0') then
                reg_read <= '1';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Status
    ---------------------------------------------------------------------------
    i2c_active <= '0' when state = IDLE else '1';
    error      <= '1' when state = IDLE and
                           (start_cond = '1' or stop_cond = '1') else '0';

end architecture behavioral;
