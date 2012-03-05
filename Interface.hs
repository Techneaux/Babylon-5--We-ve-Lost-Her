module Interface where

import Control.Concurrent.STM
import Data.Char (toLower)
import Data.Maybe (isJust, fromJust)
import Data.IntMap hiding (filter, map)

import InterfaceShow
import Ships
import Stations
import StringFunctions
import Wares
import Wrappers
import World

data UserCommand = UCGoTo StationID
                 | UCSell Ware Amount
                 | UCBuy Ware Amount
                 | UCStationInfo
                 | UCCharacterInfo
                 | UCUndock
                 | UCNavigation
                 | UCList
                 | UCTrade
                 | UCBack
              -- | UCSave
                 | UCExit
    deriving ()

instance Show UserCommand where
    show (UCGoTo i) = "goto station " ++ show i
    show (UCSell w a) = "sell " ++ show a ++ " units of " ++ show w
    show (UCBuy w a) = "buy " ++ show a ++ " units of " ++ show w
    show UCUndock = "undock"
    show UCList = "list station cargo"
    show UCExit = "exit"

instance ContextualShow UserCommand where
    contextShow (c, _) UCBack = "back"
    contextShow (c, _) UCTrade = "trade"
    contextShow (c, _) (UCGoTo i) = "go"
    contextShow (c, _) (UCSell w a) = "sell"
    contextShow (c, _) (UCBuy w a) = "buy"
    contextShow (c, _) UCUndock = "undock"
    contextShow (c, _) UCList = "list"
    contextShow (c, _) UCExit = "exit"
    contextShow (c, _) UCStationInfo = "info"
    contextShow (c, _) UCCharacterInfo = "char"

instance Eq UserCommand where
    (==) (UCGoTo _) (UCGoTo _) = True
    (==) (UCSell _ _) (UCSell _ _) = True
    (==) (UCBuy _ _) (UCBuy _ _) = True
    (==) UCUndock UCUndock = True
    (==) UCList UCList = True
    (==) UCExit UCExit = True
    (==) _ _ = False

instance Recognize Int where
    recognize i = if filter (flip elem "1234567890") i == i then Just (read i)
                                                            else Nothing

instance Recognize UserCommand where
    recognize uc = let patterns = ["go", "sell", "buy", "undock", "exit", "quit", "list", "char", "info"]
                   in case exhaustive (map toLower uc) patterns of
                       Just "go" -> recognizeGo $ words uc
                       Just "sell" -> recognizeSell $ words uc
                       Just "buy" -> recognizeBuy $ words uc
                       Just "undock" -> Just UCUndock
                       Just "exit" -> Just UCExit
                       Just "quit" -> Just UCExit
                       Just "list" -> Just UCList
                       Just "info" -> Just UCStationInfo
                       Just "char" -> Just UCCharacterInfo
                       otherwise -> Nothing

recognizeGo :: [String] -> Maybe UserCommand
recognizeGo (g:i:[]) = if (isJust $ (recognize i :: Maybe Int)) 
                            then Just $ UCGoTo (fromJust $ recognize i)
                            else Nothing
recognizeGo _ = Nothing

--      \ . /               | Rewrite those two when I get the chance
--       \|/                | that code is fucking terrible
--      --o--               | but "sell 10 fuel" and "sell fuel 10"
--        |                 | both work, which is very nice
--     kkk kkk            \ | /
--    0___0___0            \|/
recognizeSell :: [String] -> Maybe UserCommand
recognizeSell (_:w:a:[]) = let w1 = recognize w :: Maybe Ware
                               a1 = recognize a :: Maybe Amount
                               w2 = recognize a :: Maybe Ware
                               a2 = recognize w :: Maybe Amount
                           in if (isJust w1) && (isJust a1) then Just $ UCSell (fromJust w1) (fromJust a1)
                                                            else if (isJust w2) && (isJust a2) 
                                                                    then Just $ UCSell (fromJust w2) (fromJust a2)
                                                                    else Nothing
recognizeSell _ = Nothing

recognizeBuy :: [String] -> Maybe UserCommand
recognizeBuy (_:w:a:[]) = let w1 = recognize w :: Maybe Ware
                              a1 = recognize a :: Maybe Amount
                              w2 = recognize a :: Maybe Ware
                              a2 = recognize w :: Maybe Amount
                           in if (isJust w1) && (isJust a1) then Just $ UCSell (fromJust w1) (fromJust a1)
                                                            else if (isJust w2) && (isJust a2) 
                                                                    then Just $ UCBuy (fromJust w2) (fromJust a2)
                                                                    else Nothing
recognizeBuy _ = Nothing

printContext :: InterfaceState -> IO ()
printContext (ContextSpace, ScreenNavigation) = 
    putStrLn "You're in open space."
printContext ((ContextStationGuest stid), ScreenNavigation) = 
    putStrLn $ "You're on a station with ID " ++ show stid -- FIXME
printContext ((ContextStationOwner stid), ScreenNavigation) = 
    putStrLn $ "You're on a station with ID " ++ show stid -- FIXME
printContext ((ContextShipGuest shid), ScreenNavigation) = 
    putStrLn $ "You're on a ship with ID " ++ show shid -- FIXME

data UserResult = URSuccess
                | URFailure
                | URAnswer String
    deriving (Eq)

instance Show UserResult where
    show URSuccess = "Successful."
    show URFailure = "Unsuccessful."
    show (URAnswer s) = s

getValidCommand :: [UserCommand] -> IO UserCommand
getValidCommand ucs = do
    comm <- getLine
    let c = recognize comm
    if (isJust c) && (fromJust c) `elem` ucs 
        then return (fromJust c)
        else putStrLn "Nah, wrong way, sorry. Try again\n"
             >> getValidCommand ucs

chooseAvailibleCommands :: InterfaceState -> [UserCommand]
chooseAvailibleCommands (ContextSpace, ScreenNavigation) =
    [ UCCharacterInfo
    , UCExit
    , UCGoTo 0
    ]
chooseAvailibleCommands ((ContextStationGuest st), ScreenMain) =
    [ UCCharacterInfo
    , UCExit
    , UCNavigation
    , UCStationInfo
    , UCTrade
    ]
chooseAvailibleCommands ((ContextStationGuest st), ScreenNavigation) =
    [ UCBack
    , UCCharacterInfo
    , UCExit
    , UCStationInfo
    , UCUndock
    ]
chooseAvailibleCommands ((ContextStationGuest st), ScreenTrade) =
    [ UCBack
    , UCBuy Fuel 1
    , UCCharacterInfo
    , UCExit
    , UCList
    , UCSell Fuel 1
    , UCStationInfo
    ]
chooseAvailibleCommands _ = undefined

printAvailibleCommands :: [UserCommand] -> InterfaceState -> IO ()
printAvailibleCommands ucs istate = 
    putStrLn $ "You can do something of the following: " ++ (contextShowList istate ucs)

getUserCommand :: InterfaceState -> IO (UserCommand, Bool)
getUserCommand istate = do
    let cmds = chooseAvailibleCommands istate
    printContext istate
    printAvailibleCommands cmds istate
    cmd <- getValidCommand cmds
    if cmd == UCExit then return (cmd, True)
                     else return (cmd, False)

executeUserCommand :: UserCommand -> InterfaceState -> World -> IO (UserResult, InterfaceState)
executeUserCommand UCStationInfo istate w = do
    stid <- (world_ships w) !!! 0 >>= return . dockedStID
    st <- (world_stations w) !!! stid
    return (URAnswer (station_guestShow st), istate)

executeUserCommand UCCharacterInfo istate w = do
    stid <- (world_ships w) !!! 0 >>= return . dockedStID
    st <- (world_stations w) !!! stid
    return (URAnswer (station_guestShow st), istate)

executeUserCommand UCList istate@(ContextStationGuest stid, ScreenTrade) w = do
   st <- (world_stations w) !!! stid
   return (URAnswer (show $ station_stock st), istate)

executeUserCommand UCExit istate _ = return (URSuccess, istate)
executeUserCommand _ _ _ = undefined

showResult :: UserResult -> IO ()
showResult = print

getOwnerShip :: World -> IO Ship
getOwnerShip w = (world_ships w) !!! 0 -- FIXME when needed

showSituation :: World -> InterfaceState -> IO ()
showSituation w istate = do
    ownerShip <- getOwnerShip w
    let nm = ship_navModule ownerShip
    let np = navModule_position nm
    case np of
        (DockedToStation stid) -> (world_stations w) !!! stid >>= 
                                                putStrLn . station_guestShow
        (DockedToShip shid) -> (world_ships w) !!! shid >>= print
        (SNPSpace pos) -> print pos

deviseContext :: World -> IO Context
deviseContext w = do
    ownerShip <- getOwnerShip w
    let nm = ship_navModule ownerShip
    let np = navModule_position nm
    case np of
        (DockedToStation stid) -> return $ ContextStationGuest stid
        (DockedToShip shid) -> return $ ContextShipGuest shid
        (SNPSpace pos) -> return $ ContextSpace
    
interfaceCycle :: World -> InterfaceState -> IO ()
interfaceCycle world istate = do
    showSituation world istate
    (command, ifStop) <- getUserCommand istate
    (result, newIstate) <- executeUserCommand command istate world
    showResult result
    if not ifStop then interfaceCycle world newIstate
                  else return ()
