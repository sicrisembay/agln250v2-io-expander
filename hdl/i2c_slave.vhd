--------------------------------------------------------------------------------
-- Title       : I2C Slave Controller
-- Project     : I2C Slave Implementation
-- File        : i2c_slave.vhd
-- Author      : FPGA Designer
-- Created     : July 27, 2025
-- Description : Register-based I2C slave implementation
--               Supports 7-bit addressing with configurable registers
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

    -- I2C State Machine
    type i2c_state_type is (
        IDLE,
        START_DETECTED,
        ADDR_RECEIVE,
        ADDR_ACK,
        DATA_RECEIVE,
        DATA_ACK,
        DATA_SEND,
        DATA_WAIT_ACK,
        STOP_DETECTED
    );
    
    -- Internal signals
    signal state        : i2c_state_type := IDLE;
    signal next_state   : i2c_state_type;
    
    -- I2C line synchronizers and edge detection
    signal scl_sync     : std_logic_vector(2 downto 0) := (others => '1');
    signal sda_sync     : std_logic_vector(2 downto 0) := (others => '1');
    signal scl_falling  : std_logic;
    signal scl_rising   : std_logic;
    signal sda_falling  : std_logic;
    signal sda_rising   : std_logic;
    
    -- Start and stop condition detection
    signal start_cond   : std_logic;
    signal stop_cond    : std_logic;
    
    -- Shift register for receiving data
    signal shift_reg    : std_logic_vector(7 downto 0);
    signal bit_count    : unsigned(2 downto 0);
    
    -- Address matching
    signal addr_match   : std_logic;
    signal rw_bit       : std_logic;  -- 0 = write, 1 = read
    
    -- Internal registers
    signal current_reg_addr : std_logic_vector(7 downto 0);
    signal data_buffer      : std_logic_vector(7 downto 0);
    
    -- Control signals
    signal ack_bit      : std_logic;
    signal send_ack     : std_logic;
    signal send_data    : std_logic;
    
begin

    -- Synchronize I2C lines to system clock
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
    
    -- Edge detection
    scl_falling <= scl_sync(2) and not scl_sync(1);
    scl_rising  <= not scl_sync(2) and scl_sync(1);
    sda_falling <= sda_sync(2) and not sda_sync(1);
    sda_rising  <= not sda_sync(2) and sda_sync(1);
    
    -- Start and stop condition detection
    start_cond <= sda_falling when scl_sync(1) = '1' else '0';
    stop_cond  <= sda_rising when scl_sync(1) = '1' else '0';
    
    -- Main I2C state machine
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
            shift_reg <= (others => '0');
            bit_count <= (others => '0');
            addr_match <= '0';
            rw_bit <= '0';
            current_reg_addr <= (others => '0');
            data_buffer <= (others => '0');
            ack_bit <= '0';
            send_ack <= '0';
            send_data <= '0';
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    shift_reg <= (others => '0');
                    bit_count <= (others => '0');
                    addr_match <= '0';
                    send_ack <= '0';
                    send_data <= '0';
                    ack_bit <= '0';
                    
                    if start_cond = '1' then
                        state <= START_DETECTED;
                    end if;
                
                when START_DETECTED =>
                    bit_count <= (others => '0');
                    if scl_falling = '1' then
                        state <= ADDR_RECEIVE;
                    end if;
                
                when ADDR_RECEIVE =>
                    if scl_rising = '1' then
                        shift_reg <= shift_reg(6 downto 0) & sda_sync(1);
                        bit_count <= bit_count + 1;
                        
                        if bit_count = 7 then
                            -- Check if address matches
                            if shift_reg(7 downto 1) = SLAVE_ADDR then
                                addr_match <= '1';
                                rw_bit <= sda_sync(1);
                            else
                                addr_match <= '0';
                            end if;
                            state <= ADDR_ACK;
                        end if;
                    end if;
                
                when ADDR_ACK =>
                    if addr_match = '1' then
                        send_ack <= '1';
                        ack_bit <= '0';  -- Send ACK (pull SDA low)
                    else
                        send_ack <= '0';
                        ack_bit <= '1';  -- Send NACK (release SDA)
                    end if;
                    
                    if scl_falling = '1' then
                        send_ack <= '0';
                        if addr_match = '1' then
                            bit_count <= (others => '0');
                            if rw_bit = '0' then
                                state <= DATA_RECEIVE;  -- Write operation
                            else
                                state <= DATA_SEND;     -- Read operation
                                data_buffer <= reg_data_in;
                            end if;
                        else
                            state <= IDLE;
                        end if;
                    end if;
                
                when DATA_RECEIVE =>
                    if scl_rising = '1' then
                        shift_reg <= shift_reg(6 downto 0) & sda_sync(1);
                        bit_count <= bit_count + 1;
                        
                        if bit_count = 7 then
                            if current_reg_addr = x"00" then
                                -- First byte is register address
                                current_reg_addr <= shift_reg(6 downto 0) & sda_sync(1);
                            else
                                -- Subsequent bytes are data
                                data_buffer <= shift_reg(6 downto 0) & sda_sync(1);
                            end if;
                            state <= DATA_ACK;
                        end if;
                    end if;
                
                when DATA_ACK =>
                    send_ack <= '1';
                    ack_bit <= '0';  -- Send ACK
                    
                    if scl_falling = '1' then
                        send_ack <= '0';
                        bit_count <= (others => '0');
                        
                        if current_reg_addr /= x"00" then
                            -- Increment register address for auto-increment
                            current_reg_addr <= std_logic_vector(unsigned(current_reg_addr) + 1);
                        end if;
                        state <= DATA_RECEIVE;
                    end if;
                
                when DATA_SEND =>
                    if scl_falling = '1' then
                        if bit_count = 0 then
                            shift_reg <= data_buffer;
                        else
                            shift_reg <= shift_reg(6 downto 0) & '0';
                        end if;
                        bit_count <= bit_count + 1;
                        
                        if bit_count = 7 then
                            state <= DATA_WAIT_ACK;
                            send_data <= '0';
                        else
                            send_data <= '1';
                        end if;
                    end if;
                
                when DATA_WAIT_ACK =>
                    if scl_rising = '1' then
                        if sda_sync(1) = '0' then  -- ACK received
                            bit_count <= (others => '0');
                            current_reg_addr <= std_logic_vector(unsigned(current_reg_addr) + 1);
                            data_buffer <= reg_data_in;  -- Get next register data
                            state <= DATA_SEND;
                        else  -- NACK received
                            state <= IDLE;
                        end if;
                    end if;
                
                when STOP_DETECTED =>
                    state <= IDLE;
                
                when others =>
                    state <= IDLE;
                    
            end case;
            
            -- Global stop condition detection
            if stop_cond = '1' then
                state <= IDLE;
            end if;
        end if;
    end process;
    
    -- Output assignments
    process(send_ack, ack_bit, send_data, shift_reg, bit_count)
    begin
        if send_ack = '1' then
            sda_out <= ack_bit;
            sda_oe <= '1';
        elsif send_data = '1' then
            sda_out <= shift_reg(7);
            sda_oe <= '1';
        else
            sda_out <= '1';
            sda_oe <= '0';
        end if;
    end process;
    
    -- Register interface outputs
    reg_addr <= current_reg_addr;
    reg_data_out <= data_buffer;
    
    -- Write strobe generation
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            reg_write <= '0';
        elsif rising_edge(clk) then
            reg_write <= '0';
            if state = DATA_ACK and send_ack = '1' and current_reg_addr /= x"00" then
                reg_write <= '1';
            end if;
        end if;
    end process;
    
    -- Read strobe generation
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            reg_read <= '0';
        elsif rising_edge(clk) then
            reg_read <= '0';
            if (state = ADDR_ACK and rw_bit = '1' and addr_match = '1') or
               (state = DATA_WAIT_ACK and sda_sync(1) = '0') then
                reg_read <= '1';
            end if;
        end if;
    end process;
    
    -- Status outputs
    i2c_active <= '1' when state /= IDLE else '0';
    error <= '1' when state = IDLE and (start_cond = '1' or stop_cond = '1') else '0';

end architecture behavioral;
