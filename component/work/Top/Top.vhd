----------------------------------------------------------------------
-- Created by SmartDesign Fri Mar 20 13:52:22 2026
-- Version: v11.9 SP6 11.9.6.7
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Libraries
----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library igloo;
use igloo.all;
----------------------------------------------------------------------
-- Top entity declaration
----------------------------------------------------------------------
entity Top is
    -- Port list
    port(
        -- Inputs
        BTN1 : in  std_logic;
        BTN2 : in  std_logic;
        BTN3 : in  std_logic;
        BTN4 : in  std_logic;
        -- Outputs
        LED1 : out std_logic;
        LED2 : out std_logic;
        LED3 : out std_logic;
        LED4 : out std_logic;
        LED5 : out std_logic;
        LED6 : out std_logic;
        LED7 : out std_logic;
        LED8 : out std_logic
        );
end Top;
----------------------------------------------------------------------
-- Top architecture body
----------------------------------------------------------------------
architecture RTL of Top is
----------------------------------------------------------------------
-- Signal declarations
----------------------------------------------------------------------
signal BTN1_net_0 : std_logic;
signal BTN1_net_1 : std_logic;
signal LED3_net_0 : std_logic;
signal LED3_net_1 : std_logic;
signal BTN3_net_0 : std_logic;
signal BTN3_net_1 : std_logic;
signal BTN4_net_0 : std_logic;
signal BTN4_net_1 : std_logic;

begin
----------------------------------------------------------------------
-- Top level output port assignments
----------------------------------------------------------------------
 BTN1_net_0 <= BTN1;
 LED1       <= BTN1_net_0;
 BTN1_net_1 <= BTN1;
 LED2       <= BTN1_net_1;
 LED3_net_0 <= BTN2;
 LED3       <= LED3_net_0;
 LED3_net_1 <= BTN2;
 LED4       <= LED3_net_1;
 BTN3_net_0 <= BTN3;
 LED5       <= BTN3_net_0;
 BTN3_net_1 <= BTN3;
 LED6       <= BTN3_net_1;
 BTN4_net_0 <= BTN4;
 LED7       <= BTN4_net_0;
 BTN4_net_1 <= BTN4;
 LED8       <= BTN4_net_1;

end RTL;
