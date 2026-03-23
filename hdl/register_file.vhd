--------------------------------------------------------------------------------
-- Title       : Register File for I2C Slave
-- Project     : I2C Slave Implementation
-- File        : register_file.vhd
-- Author      : Sicris Rey Embay
-- Created     : July 27, 2025
-- Description : Simple register file with read/write capabilities
--               for use with I2C slave controller
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity register_file is
    generic (
        NUM_REGS : integer := 16                    -- Number of registers
    );
    port (
        -- System signals
        clk         : in  std_logic;                -- System clock
        rst_n       : in  std_logic;                -- Active low reset
        
        -- Register interface
        reg_addr    : in  std_logic_vector(7 downto 0);  -- Register address
        reg_data_in : in  std_logic_vector(7 downto 0);  -- Data to write
        reg_data_out: out std_logic_vector(7 downto 0);  -- Data read
        reg_write   : in  std_logic;                     -- Write enable
        reg_read    : in  std_logic;                     -- Read enable
        
        -- Application interface (example registers)
        control_reg : out std_logic_vector(7 downto 0);  -- Control register (addr 0x01)
        status_reg  : in  std_logic_vector(7 downto 0);  -- Status register (addr 0x02)
        data_reg0   : out std_logic_vector(7 downto 0);  -- Data register 0 (addr 0x04)
        data_reg1   : out std_logic_vector(7 downto 0);  -- Data register 1 (addr 0x05)
        data_reg2   : out std_logic_vector(7 downto 0);  -- Data register 2 (addr 0x06)
        data_reg3   : out std_logic_vector(7 downto 0)   -- Data register 3 (addr 0x07)
    );
end entity register_file;

architecture behavioral of register_file is

    -- Register memory array
    type reg_array_type is array (0 to NUM_REGS-1) of std_logic_vector(7 downto 0);
    signal registers : reg_array_type;
    
    -- Register address as integer
    signal addr_int : integer range 0 to 255;
    
    -- Internal register assignments
    constant ID_REG_ADDR      : integer := 0;   -- Device ID register (read-only)
    constant CONTROL_REG_ADDR : integer := 1;   -- Control register
    constant STATUS_REG_ADDR  : integer := 2;   -- Status register (read-only)
    constant VERSION_REG_ADDR : integer := 3;   -- Version register (read-only)
    constant DATA_REG0_ADDR   : integer := 4;  -- Data register 0
    constant DATA_REG1_ADDR   : integer := 5;  -- Data register 1
    constant DATA_REG2_ADDR   : integer := 6;  -- Data register 2
    constant DATA_REG3_ADDR   : integer := 7;  -- Data register 3
    
    -- Default values
    constant DEVICE_ID        : std_logic_vector(7 downto 0) := x"A5";  -- Device ID
    constant VERSION_INFO     : std_logic_vector(7 downto 0) := x"10";  -- Version 1.0 (major (bit7:4) = 1, minor (bit3:0)=0)

begin

    -- Convert address to integer
    addr_int <= to_integer(unsigned(reg_addr)) when to_integer(unsigned(reg_addr)) < NUM_REGS else 0;
    
    -- Register write process
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            -- Initialize registers with default values
            registers <= (others => (others => '0'));
            registers(ID_REG_ADDR) <= DEVICE_ID;
            registers(VERSION_REG_ADDR) <= VERSION_INFO;
        elsif rising_edge(clk) then
            -- Update status register from external signal
            registers(STATUS_REG_ADDR) <= status_reg;
            
            -- Handle register writes
            if reg_write = '1' then
                case addr_int is
                    when CONTROL_REG_ADDR =>
                        registers(CONTROL_REG_ADDR) <= reg_data_in;
                    
                    when DATA_REG0_ADDR =>
                        registers(DATA_REG0_ADDR) <= reg_data_in;
                    
                    when DATA_REG1_ADDR =>
                        registers(DATA_REG1_ADDR) <= reg_data_in;
                    
                    when DATA_REG2_ADDR =>
                        registers(DATA_REG2_ADDR) <= reg_data_in;
                    
                    when DATA_REG3_ADDR =>
                        registers(DATA_REG3_ADDR) <= reg_data_in;
                    
                    when others =>
                        -- Read-only registers or invalid addresses - do nothing
                        null;
                end case;
            end if;
        end if;
    end process;
    
    -- Register read: combinatorial (asynchronous) output so the I2C slave can
    -- sample the requested register value immediately without a pipeline bubble.
    process(addr_int, registers)
    begin
        if addr_int < NUM_REGS then
            reg_data_out <= registers(addr_int);
        else
            reg_data_out <= (others => '0');
        end if;
    end process;
    
    -- Output register values to application interface
    control_reg <= registers(CONTROL_REG_ADDR);
    data_reg0   <= registers(DATA_REG0_ADDR);
    data_reg1   <= registers(DATA_REG1_ADDR);
    data_reg2   <= registers(DATA_REG2_ADDR);
    data_reg3   <= registers(DATA_REG3_ADDR);

end architecture behavioral;