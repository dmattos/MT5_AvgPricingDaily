#include <Trade\Trade.mqh>

// Create a trade object
CTrade trade;

// Input parameters
input string Symbol = "SRNA3F";             // Symbol to trade
input double TotalInvestment = 30000.0;     // Total amount to invest (BRL)
input double StopLossPct = 0.4;             // Stop loss percentage (e.g., 40%)
input int DurationInDays = 90;              // Investment duration in days

// Constants for state persistence
#define STATE_TOTAL_SHARES "TotalSharesBought"
#define STATE_TOTAL_COST   "TotalCost"
#define STATE_LAST_BUY     "LastBuyTime"
#define STATE_STOPLOSS_TRIGGERED "StopLossTriggered"

// Variables
double DailyInvestment;
double TotalSharesBought = 0;
double TotalCost = 0;                       // Total amount spent
double AveragePrice = 0;                    // Weighted average price
datetime StartDate;
datetime LastBuyTime;
bool StopLossTriggered = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Calculate daily investment
    DailyInvestment = TotalInvestment / DurationInDays;
    StartDate = TimeCurrent();

    // Restore state
    if(GlobalVariableCheck(STATE_TOTAL_SHARES))
        TotalSharesBought = GlobalVariableGet(STATE_TOTAL_SHARES);
    if(GlobalVariableCheck(STATE_TOTAL_COST))
        TotalCost = GlobalVariableGet(STATE_TOTAL_COST);
    if(GlobalVariableCheck(STATE_LAST_BUY))
        LastBuyTime = (datetime)GlobalVariableGet(STATE_LAST_BUY);
    else
        LastBuyTime = StartDate - 86400; // Ensures first buy executes

    if(GlobalVariableCheck(STATE_STOPLOSS_TRIGGERED))
        StopLossTriggered = (bool)GlobalVariableGet(STATE_STOPLOSS_TRIGGERED);

    if(TotalSharesBought > 0)
        AveragePrice = TotalCost / TotalSharesBought;

    Print("EA Initialized. Daily Investment = ", DailyInvestment, " BRL. Restored state: TotalSharesBought = ",
          TotalSharesBought, ", TotalCost = ", TotalCost, ", AveragePrice = ", AveragePrice, ", StopLossTriggered = ", StopLossTriggered);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1) If the stop loss has already been triggered, do nothing
    if(StopLossTriggered)
    {
        Print("Stop loss has been triggered previously. EA will not execute further actions.");
        return; // We truly stop here—no more buys, no repeated closures.
    }

    // 2) Decide if we can still buy shares today
    bool canBuy = (TimeCurrent() <= (StartDate + DurationInDays * 86400));
    if(!canBuy)
    {
        Print("Investment period completed. Total shares bought: ", TotalSharesBought, 
              ", Average price: ", AveragePrice);
        // Note: We do NOT return here, so the Stop Loss check can still happen below
    }
    else
    {
        // 3) Only buy once per day
        if(TimeCurrent() - LastBuyTime >= 86400)
        {
            double Ask = SymbolInfoDouble(Symbol, SYMBOL_ASK);
            if(Ask <= 0)
            {
                Print("Error fetching Ask price for symbol: ", Symbol, 
                      ". Error code: ", GetLastError());
            }
            else
            {
                int SharesToBuy = (int)MathFloor(DailyInvestment / Ask);
                if(SharesToBuy <= 0)
                {
                    Print("Insufficient funds for today's purchase. DailyInvestment: ", 
                          DailyInvestment, ", Ask: ", Ask);
                }
                else
                {
                    // Attempt to buy
                    if(trade.Buy(SharesToBuy, Symbol, Ask, 0, 0, "Daily Share Purchase"))
                    {
                        Print("Bought ", SharesToBuy, " shares of ", Symbol, " at ", Ask);

                        // Update statistics
                        TotalSharesBought += SharesToBuy;
                        TotalCost += SharesToBuy * Ask;
                        AveragePrice = TotalCost / TotalSharesBought;
                        LastBuyTime = TimeCurrent();

                        // Save state
                        GlobalVariableSet(STATE_TOTAL_SHARES, TotalSharesBought);
                        GlobalVariableSet(STATE_TOTAL_COST, TotalCost);
                        GlobalVariableSet(STATE_LAST_BUY, LastBuyTime);
                    }
                    else
                    {
                        Print("Error placing buy order. Error code: ", GetLastError());
                    }
                }
            }
        }
    }

    // 4) Stop Loss check should *always* be performed, regardless of canBuy
    double CurrentPrice = SymbolInfoDouble(Symbol, SYMBOL_BID);
    if(CurrentPrice <= 0)
    {
        Print("Error fetching Bid price for symbol: ", Symbol, 
              ". Error code: ", GetLastError());
        return;
    }

    double StopLossPrice = AveragePrice * (1.0 - StopLossPct);
    Print("Checking Stop Loss: CurrentPrice = ", CurrentPrice, 
          ", StopLossPrice = ", StopLossPrice);

    if(CurrentPrice < StopLossPrice)
    {
        Print("Stop Loss condition met. CurrentPrice (", CurrentPrice, 
              ") < StopLossPrice (", StopLossPrice, "). Initiating closure of positions.");

        StopLossTriggered = true;
        GlobalVariableSet(STATE_STOPLOSS_TRIGGERED, StopLossTriggered);

        // Close all positions
        CloseAllPositionsCustom();
    }
}


//+------------------------------------------------------------------+
//| Function to close all positions with specific logic              |
//+------------------------------------------------------------------+
void CloseAllPositionsCustom()
{
    int total_positions = PositionsTotal();
    Print("Total open positions: ", total_positions);

    // Iterate through all open positions
    for(int i = total_positions - 1; i >= 0; i--)
    {
        // Select the position by index
        if(!PositionGetTicket(i))
        {
            Print("Failed to select position at index ", i, ". Error code: ", GetLastError());
            continue;
        }

        // Retrieve position details
        string symbol = PositionGetString(POSITION_SYMBOL);
        double volume = PositionGetDouble(POSITION_VOLUME);
        ulong ticket = PositionGetInteger(POSITION_TICKET);
        int type = (int)PositionGetInteger(POSITION_TYPE); // POSITION_TYPE_BUY or POSITION_TYPE_SELL

        // Determine if the symbol is fractional
        bool is_fractional = false;
        string base_symbol = symbol;

        if(StringLen(symbol) > 1 && StringSubstr(symbol, StringLen(symbol) - 1, 1) == "F")
        {
            is_fractional = true;
            base_symbol = StringSubstr(symbol, 0, StringLen(symbol) - 1); // Remove the "F"
        }

        if(is_fractional)
        {
            Print("Processing fractional position: Symbol=", symbol, ", Volume=", volume);

            // Calculate the number of full 100-share lots
            int multiples = (int)MathFloor(volume / 100.0);
            double remaining = volume - (multiples * 100.0);

            // Sell multiples as regular symbol
            if(multiples > 0)
            {
                string regular_symbol = base_symbol;
                double ask_price = SymbolInfoDouble(regular_symbol, SYMBOL_ASK);

                if(ask_price <= 0)
                {
                    Print("Invalid Ask price for symbol ", regular_symbol, ". Skipping sell order for multiples.");
                }
                else
                {
                    double sell_volume = multiples * 100.0;

                    // Execute sell order for regular symbol
                    if(trade.Sell(sell_volume, regular_symbol, ask_price, 0, 0, "Close multiples of 100"))
                    {
                        Print("Successfully sold ", sell_volume, " shares of ", regular_symbol, " at ", ask_price);
                    }
                    else
                    {
                        Print("Failed to sell ", sell_volume, " shares of ", regular_symbol, ". Error code: ", GetLastError());
                    }
                }
            }

            // Sell remaining shares as fractional symbol
            if(remaining > 0.0)
            {
                string fractional_symbol = symbol;
                double ask_price = SymbolInfoDouble(fractional_symbol, SYMBOL_ASK);

                if(ask_price <= 0)
                {
                    Print("Invalid Ask price for symbol ", fractional_symbol, ". Skipping sell order for remaining shares.");
                }
                else
                {
                    double sell_volume = remaining;

                    // Execute sell order for fractional symbol
                    if(trade.Sell(sell_volume, fractional_symbol, ask_price, 0, 0, "Close remaining shares"))
                    {
                        Print("Successfully sold ", sell_volume, " shares of ", fractional_symbol, " at ", ask_price);
                    }
                    else
                    {
                        Print("Failed to sell ", sell_volume, " shares of ", fractional_symbol, ". Error code: ", GetLastError());
                    }
                }
            }
        }
        else
        {
            Print("Processing regular position: Symbol=", symbol, ", Volume=", volume);

            // Close regular position directly
            if(trade.PositionClose(symbol))
            {
                Print("Successfully closed position: Ticket=", ticket, ", Symbol=", symbol, ", Volume=", volume);
            }
            else
            {
                Print("Failed to close position: Ticket=", ticket, ". Error code: ", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("EA Deinitialized. Total shares bought: ", TotalSharesBought, ", Average price: ", AveragePrice);
}
