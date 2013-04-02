module World where

import Control.Applicative ((<$>))
import Control.Concurrent
import Control.Concurrent.STM hiding (check)
import Control.Monad (forM)
import Control.Monad.Reader
import qualified Data.Map as M
import Data.Maybe (isJust, fromJust)
import Data.IntMap hiding (filter, null, map)   -- to avoid confusion when
import qualified Data.IntMap as I (filter, map) -- using filter and map,
import Prelude hiding (filter, map)             -- I import them qualified,
import qualified Prelude as P (filter, map)     -- 'cuz it cost me 20 minutes once
import Data.List (foldl') -- non-alphabetical so that I could write the above comment
import System.Posix (sleep) -- first non-cross-platform line in the code

import AI
import Auxiliary.IntMap
import qualified Auxiliary.Map as M1
import Auxiliary.StringFunctions
import Auxiliary.STM
import Auxiliary.Tuples
import Currency
import DataTypes
import Data.Everything
import GlobalConst
import Navigation
import NavigationIO
import Interface
import Owner
import Parsable
import Ships
import ShipsAndStations
import Space
import Stock
import System.Console.ANSI
import Transactions
import qualified Vector as V
import Wares
import WorldGenerator
import Wrappers

-- File contents, [INDEX] stands for `search for the bracketed word 
--                                  to get to the section mentioned`
--
-- [WORLD] - World data type has been moved to DataTypes, 
--           function for world-making are in WorldGenerator.hs
--           wrappers for `global` IntMaps and some auxiliary functions are still here
--
-- [GLOBTVAR] - functions for dealing with stuff inside the `global` IntMaps
--              quite rarely used, tbh, but possibly useful
--
-- [READFN] - functions inside ReaderT World that can be used
--            inside the game cycle with just >>
--            note that all the really cool stuff happens here
--
-- [PRINT] - debug function. But it prints the whole world! Ain't that somethin'
--
-- [PROCESS] - functions that process one particular `global` IntMap
--             like, update station tax revenues, burn ships fuel and so on
--             several auxiliary fns included


-- SECTION BREAK
-- [WORLD] -- see section description in the contents above

pause :: MVar () -> IO ()
pause a = takeMVar a

unpause :: MVar () -> IO ()
unpause a = putMVar a ()

makeNewWorld :: Owner -> Ship -> IO World
makeNewWorld owner ship = do
    w <- atomically $ generateWorld
    addInstanceTo (world_owners w) owner 0
    addInstanceTo (world_ships w) ship 0
    return w

-- this fn also exists in WorldGenerator.hs FIXME    
intMapToTVarIntMap :: IntMap a -> STM (IntMap (TVar a))
intMapToTVarIntMap ias = mapM newTVar vals >>= return . fromList . (zip keys)
                         where keys = P.map fst (toList ias)
                               vals = P.map snd (toList ias)

          -- stop lock  pause lock
gameCycle :: TVar Bool -> MVar () -> ReaderT World IO ()
gameCycle slock plock = do
  cycleEverything
  liftIO $ sleep (fromIntegral tickReal)
  stop <- liftIO $ readTVarIO slock
  if (not stop) 
    then (liftIO . readMVar) plock >> gameCycle slock plock
    else return ()

gameCycleIO :: World -> TVar Bool -> MVar () -> IO ()
gameCycleIO w slock plock = runReaderT (gameCycle slock plock) w


-- SECTION BREAK
-- [GLOBTVAR] -- see section description in the contents above

(!!!) :: TVar (IntMap (TVar a)) -> Int -> IO a
(!!!) tas i = readTVarIO tas >>= \imap -> readTVarIO (imap ! i)

modifyGlobalTVar :: (IntMap a -> IntMap a) -> TVar (IntMap a) -> IO ()
modifyGlobalTVar fn tas = atomically $
                          readTVar tas >>= \as ->
                          writeTVar tas (fn as)

-- inserts an entry into a TVar'ed IntMap
insertIntoGlobalTVar :: a -> TVar (IntMap a) -> IO ()
insertIntoGlobalTVar a tas = modifyGlobalTVar (insertMax a) tas

-- Kills every entry satisfying given predicate
deleteWithFromGlobalTVar :: (a -> Bool) -> TVar (IntMap a) -> IO ()
deleteWithFromGlobalTVar pred tas = modifyGlobalTVar (I.filter $ not . pred) tas

-- Applies modifier function to every entry satisfying given predicate
modifyInGlobalTVar :: (a -> Bool) -> (a -> a) -> TVar (IntMap a) -> IO ()
modifyInGlobalTVar predicate modifier tas =
    let mod = I.map (\a -> if predicate a then modifier a else a)
    in modifyGlobalTVar mod tas


-- SECTION BREAK
-- [READFN] -- see section description in the contents above

cycleEverything :: ReaderT World IO ()
cycleEverything = do
    world <- ask
    let owners = world_owners world
    let ships = world_ships world
    let stations = world_stations world
    let time = world_time world
    --lift $ putStrLn "Updating owners."
    liftIO $ cycleClass owners
    --lift $ putStrLn "Updating stations."
    liftIO $ cycleClass stations 
    --lift $ putStrLn "Updating ships."
    lift $ processIT ships
    -- liftIO $ cycleClass ships 
    --lift $ putStrLn "Processing docking."
    liftIO $ processDocking ships stations
    --lift $ putStrLn "Processing undocking."
    liftIO $ processUndocking ships stations
    --liftIO $ putStrLn "Updating time."
    lift (readTVarIO time) >>= lift . atomically . (writeTVar time) . (1+)

-- printWorld :: ReaderT World IO ()
-- printWorld = do
--     world <- ask
--     liftIO $ putStrLn "\n\nShowing stations:"
--     liftIO $ putStrLn "Sorry, disabled for weird reasons. See Mar 5th, 21:02"
--     liftIO $ putStrLn "\n\nShowing ships:"
--     liftIO $ printClass (world_ships world)
--     liftIO $ putStrLn "\n\nShowing owners:"
--     liftIO $ printClass (world_owners world)


-- SECTION BREAK
-- [PRINT] -- see section description in the contents above

printClass :: (Show a) => TVar (IntMap (TVar a)) -> IO ()
printClass tmap = readTVarIO tmap >>=
    (mapM readTVarIO) . (P.map snd) . toList >>= mapM_ print 


-- SECTION BREAK
-- [PROCESS] -- see section description in the contents above

class Processable a where
    process :: TVar a -> IO ()
    processSTM :: TVar a -> STM ()
    process = atomically . processSTM
    processIT :: TVar (IntMap (TVar a)) -> IO ()
    processIT = atomically . (mapIT processSTM)

instance Processable Station where
    process tst = atomically $
        readTVar tst >>= (writeTVar tst) . stationFns
        where stationFns = foldl' (.) id
                                  [ (\st -> addMoney 3000 st) -- example tax income
                                  ]

instance Processable Owner where
    process _ = return ()

instance Processable Ship where
    processSTM tsh = do
      sh <- readTVar tsh
      let nm = ship_navModule sh
      writeTVar tsh sh{ ship_navModule = tickMove nm }

cycleClass :: (Processable a) => TVar (IntMap (TVar a)) -> IO ()
cycleClass timap = readTVarIO timap >>= \imap -> 
                                 mapM_ (\k -> process (imap ! k)) (keys imap)

-- Appendix-like remain. I let it stay for clearness its name provides just once
dockMissing :: Ships -> Stations -> IO ()
dockMissing = processDocking

processDocking :: Ships -> Stations -> IO ()
processDocking tships tstations = atomically $ do
  needDocking <- filterIT docking tships
  dockingStations <- mapM (checkT dockingSt) needDocking
  mapM_ (uncurry dockShSt) (zip needDocking dockingStations)

dockShSt :: (TVar Ship) -> (TVar Station) -> STM ()
dockShSt tsh tst = do
  ship <- readTVar tsh
  writeTVar tsh ship{ ship_navModule = NavModule (DockedToStation tst) Idle []}
  station <- readTVar tst
  writeTVar tst station{ station_dockingBay =
                          if tsh `notElem` (station_dockingBay station)
                            then (station_dockingBay station) ++ [tsh] 
                            else station_dockingBay station }

processUndocking :: Ships -> Stations -> IO ()
processUndocking tships tstations = atomically $ do
  needUndocking <- filterIT undocking tships
  undockingStations <- mapM (checkT dockingSt) needUndocking
  mapM_ (uncurry undockShSt) (zip needUndocking undockingStations)

undockShSt :: (TVar Ship) -> (TVar Station) -> STM ()
undockShSt tsh tst = do

  ship <- readTVar tsh
  shipPos <- checkT station_position tst >>= return . departureAround 
  let navm = ship_navModule ship
  writeTVar tsh ship{ ship_navModule = 
    navm{ navModule_position = SNPSpace shipPos 
        , navModule_status = Idle } }

  station <- readTVar tst
  writeTVar tst station{ station_dockingBay =
                          P.filter (/= tsh) (station_dockingBay station) }

processJumping :: Ships -> IO ()
processJumping tshs = 
  readTVarIO tshs >>= atomically . (filterT jumping) . vals >>= (mapM_ jumpSh)

jumpSh :: (TVar Ship) -> IO ()
jumpSh tsh = do
  sh <- readTVarIO tsh
  let dstype =
        case navModule_status (ship_navModule sh) of
          (Jumping _ stype) -> stype
          otherwise -> error "World: jumpSh: navModule_status <> jumping"
  let cstype = nav_pos_type $ spacePosition sh
  entryPos <- atomically $ getJumpEnginePos (navModule_status $ ship_navModule sh) cstype
  newPos <- liftIO $ jump entryPos dstype
  let newModule = (NavModule (SNPSpace newPos) Idle (navModule_program (ship_navModule sh)))
  atomically $ writeTVar tsh sh{ ship_navModule = newModule }

-- processNavPrograms :: Ships -> IO ()
-- processNavPrograms = mapM (atomically . processNavProgram)
-- 
-- processNavProgram :: (TVar Ship) -> STM ()
-- processNavProgram tsh = do
--   sh <- readTVar tsh
--   let nprog = 
-- 
setOnCourse :: (TVar Ship) -> (TVar Station) -> STM ()
setOnCourse = setShipOnCourse

runInterface :: World -> IO ()
runInterface w = setCursorPosition 0 0 >> clearFromCursorToScreenEnd >>
  setCursorPosition 5 0 >> runReaderT interface w

-- To link together `ReaderT World IO (TVar sth)' and `ReaderT World STM (TVar sth)'
-- one can pass an accessor (readTVarIO and readTVar respectively) into a reader:
-- getPlayerWith accessor = 
--   ask >>= lift . accessor . world_owners >>= return . (\a -> a ! 0)
--
-- This is the type signature, borrowing from ghci:
-- getPlayerWith
--  :: ( EnvType (t, m) ~ World
--     , MonadReader (t, m)
--     , MonadTrans t
--     , Monad m) =>
--     (TVar (IntMap (TVar Ship)) -> m (IntMap b)) -> t m b

stmRtoIoR :: ReaderT a STM r -> ReaderT a IO r
stmRtoIoR r1 = ask >>= liftIO . atomically . (runReaderT r1)

getPlayerShipSTM :: ReaderT World STM (TVar Ship) -- FIXME it shouldn't be Ships ! 0
getPlayerShipSTM = ask >>= lift . readTVar . world_ships >>= return . (\a -> a ! 0)

getPlayerSTM :: ReaderT World STM (TVar Owner) -- FIXLE it shouldn't be Owners ! 0
getPlayerSTM = ask >>= lift . readTVar . world_owners >>= return . (\a -> a ! 0)

getPlayerShipIO :: ReaderT World IO (TVar Ship)
getPlayerShipIO = stmRtoIoR getPlayerShipSTM

getPlayerIO :: ReaderT World IO (TVar Owner)
getPlayerIO = stmRtoIoR getPlayerSTM

data Menu_ActionAfter =
  MAA_Depends
  | MAA_Finish
  | MAA_Return
  deriving ()

data Menu_Result =
  MR_Pop
  | MR_Stay
  | MR_Top
  deriving ()
  
type Menu a = M.Map String (ReaderT a STM Bool, ReaderT a IO Menu_Result, Menu_ActionAfter)

processMenu :: Menu a -> ReaderT a IO ()
processMenu menu = do
  context <- ask
  filteredOptionsList <- filterM (\(_,(b,_,_)) -> stmRtoIoR b) (M.toList menu)
  let filteredMenu = M.fromList (P.map (\(a,(_,c,d)) -> (a,(c,d))) filteredOptionsList)
  a <- liftIO $ getByNum (M.keys filteredMenu)
  lift $ setCursorPosition 0 0 >> clearFromCursorToScreenEnd >> setCursorPosition 5 0
  liftIO $ putStrLn $ "> " ++ a ++ "\n"
  result <- fst (filteredMenu M.! a)
  case result of
    MR_Stay -> processMenu menu
    otherwise ->
      case snd (filteredMenu M.! a) of
        MAA_Return -> processMenu menu
        otherwise -> return ()

interfaceOptions :: Menu World
interfaceOptions = M.fromList
  [ ("Navigation", (return True , runNavigationW, MAA_Return))
  , ("Trade"     , (dockedW     , runTradeW     , MAA_Return))
  , ("Quit"      , (return True , return MR_Top , MAA_Finish))
  ]

interface = processMenu interfaceOptions

dockedW :: ReaderT World STM Bool
dockedW = do
  w <- ask
  ships <- lift $ readTVar (world_ships w)
  sh <- lift $ readTVar (ships ! 0)
  return (isJust $ dockedM sh)

navigationOptions :: Menu NavContext
navigationOptions = M.fromList
  [ ("Display coordinates", (return True  , navDisplay   , MAA_Return))
  , ("Dock"               , (stationNearby, navDock      , MAA_Finish))
  , ("Undock"             , (docked       , navUndock    , MAA_Finish))
  , ("Set course"         , (undocked     , navSetCourse , MAA_Depends))
  ]

navigation = processMenu navigationOptions

docked = ask >>= return . isJust . nc_dockedTo 
undocked = docked >>= return . not

navDisplay :: ReaderT NavContext IO (Menu_Result)
navDisplay = do
  w <- ask
  tstm <- stmRtoIoR stationNearbyM
  pos <- liftIO $ atomically $ liftToTVar spacePosition (nc_ownerShip w)
  vel <- liftIO $ atomically $ 
    checkT (navMoving_velocity . navModule_status . ship_navModule) (nc_ownerShip w)
  liftIO $ putStrLn $ "\nYour coordinates are: " ++ show pos
  liftIO $ putStrLn $ "Your velocity is: " ++ show vel
  if isJust tstm 
    then liftIO (readTVarIO $ fromJust tstm) >>= \st ->
      (liftIO $ putStrLn $ "You're near a station: " ++ station_name st ++ "\n") 
      >> return MR_Stay
    else return MR_Stay

navDock :: ReaderT NavContext IO (Menu_Result)
navDock = do
  nc@(NavContext tsh _ _) <- ask
  tstm <- stmRtoIoR stationNearbyM
  let tst = fromJust tstm
  liftIO $ atomically (startDockingTo tsh tst)
  return MR_Pop

navUndock :: ReaderT NavContext IO (Menu_Result)
navUndock = do
  (NavContext tsh _ _) <- ask
  liftIO $ atomically (startUndocking tsh)
  return MR_Pop
  
stationNearbyM :: ReaderT NavContext STM (Maybe (TVar Station))
stationNearbyM = do
  nc <- ask
  let tsts = nc_allStations nc
  let tsh = nc_ownerShip nc 
  sh <- lift $ readTVar tsh
  closeStations <- lift $ filterM (\tst -> readTVar tst >>= \st -> return $ spaceDistance sh st < 1) tsts
  if null closeStations
    then return Nothing
    else return $ Just $ head closeStations

stationNearby :: ReaderT NavContext STM Bool
stationNearby = stationNearbyM >>= return . isJust

data NavContext = NavContext
  { nc_ownerShip :: TVar Ship
  , nc_allStations :: [TVar Station]
  , nc_dockedTo :: Maybe (TVar Station)
  }

runNavigationW :: ReaderT World IO (Menu_Result)
runNavigationW = genNavContext >>= lift . (runReaderT navigation) >> return MR_Top

genNavContext :: ReaderT World IO NavContext
genNavContext = do
  w <- ask
  tsts <- liftIO $ readTVarIO (world_stations w) >>= return . vals
  tsh  <- getPlayerShipIO
  docked <- liftIO $ readTVarIO tsh >>= return . dockedM
  return (NavContext tsh tsts docked)

navSetCourse :: ReaderT NavContext IO (Menu_Result)
navSetCourse = do
  navContext <- ask
  let tsh = nc_ownerShip navContext
  rsts <- stmRtoIoR reachableStations
  liftIO $ showNumberedStationList rsts
  mtst <- getDestination
  if isJust mtst 
    then do 
      stName <- liftIO (readTVarIO (fromJust mtst) >>= return . station_name)
      liftIO $ putStrLn $ "You've successfully chosen a destination. It would appear " ++
                          "you're heading towards " ++ stName ++ " now."
      liftIO $ atomically $ setOnCourse tsh (fromJust mtst)
      return MR_Pop
    else do
      liftIO $ print "Nothing really happened."
      return MR_Stay

navTravelW :: World -> MVar () -> IO ()
navTravelW w plock = runReaderT (navTravel plock) w

navTravel :: MVar () -> ReaderT World IO ()
navTravel plock = getPlayerShipIO >>= lift . atomically . (checkT isIdle) >>= \b ->
    if b
      then interface
      else do
        lift $ putStrLn "Travel engaged. Press any key to stop time. "
        slock <- lift $ newTVarIO False
        ask >>= lift . forkIO . (navTravelRedrawIO slock)
        lift getChar
        lift $ atomically $ writeTVar slock True
        lift $ pause plock

navTravelRedrawIO :: TVar Bool -> World -> IO ()
navTravelRedrawIO slock w = runReaderT (navTravelRedraw slock) w

navTravelRedraw :: TVar Bool -> ReaderT World IO ()
navTravelRedraw slock = do
  lift $ setCursorPosition 0 0 >> clearFromCursorToScreenEnd >> setCursorPosition 3 0
  tsh <- getPlayerShipIO
  genNavContext >>= lift . (runReaderT navDisplay)
  ask >>= liftIO . readTVarIO . world_time >>= \t ->
    lift (putStrLn $ "Ticks AD: " ++ show t)
  liftIO $ sleep (fromIntegral tickReal)
  programEmpty <- lift $ atomically $ 
    checkT (null . navModule_program . ship_navModule) tsh
  shipIdle <- lift $ atomically $
    checkT isIdle tsh
  if programEmpty && shipIdle
    then lift (putStrLn "\nThe ship has stopped." >> atomically (writeTVar slock True))
    else return ()
  liftIO (readTVarIO slock) >>= \stop ->
    if stop then return ()
            else navTravelRedraw slock

stationNames :: [TVar Station] -> STM [String]
stationNames tsts = do
  sts <- mapM readTVar tsts
  let names = P.map station_name sts
  return names

showNumberedList :: [String] -> IO ()
showNumberedList names = do
  let numbers  = P.map (\i -> show i ++ ". ") [1..(length names)]
  let stations = zipWith (++) numbers names
  let line = concatWith "\n" stations
  putStrLn line

showNumberedStationList :: [TVar Station] -> IO ()
showNumberedStationList tsts = do
  names <- atomically $ stationNames tsts
  showNumberedList names

reachableStations :: ReaderT NavContext STM [TVar Station]
reachableStations = ask >>= return . nc_allStations
  --shouldn't mark ALL stations as reachable FIXME

formParser :: [TVar Station] -> String -> Maybe (TVar Station)
formParser = getParsedByNum

getDestination :: ReaderT NavContext IO (Maybe (TVar Station))
getDestination = do
  sts <- nc_allStations <$> ask
  input <- liftIO getLine
  return $ formParser sts input

type TradeContext = (TVar Owner, TVar Ship, TVar Station)

runTradeW :: ReaderT World IO (Menu_Result)
runTradeW = do
  w <- ask
  to  <- getPlayerIO
  tsh <- getPlayerShipIO 
  tst <- liftIO $ readTVarIO tsh >>= return . dockedSt
  lift $ runReaderT trade (to, tsh, tst)
  return MR_Pop

runTrade :: TVar Owner -> TVar Ship -> TVar Station -> IO ()
runTrade to ts tst = runReaderT trade (to, ts, tst)

trade :: ReaderT TradeContext IO ()
trade = do
  action <- liftIO getLine
  case parseAnyOf allTradeActions action of
    (Just (Buy  (w,a) )) -> do
      buy  w a
      liftIO $ putStrLn $ "You buy " ++ show a ++ " of " ++ show w
    (Just (Sell (w,a) )) -> do
      sell w a
      liftIO $ putStrLn $ "You sell " ++ show a ++ " of " ++ show w
    Nothing -> trade
  if action == "quit"
    then return ()
    else trade

canBuy :: Ware -> Amount -> ReaderT TradeContext IO Bool
canBuy bw ba = do
  (to, tsh, tst) <- ask
  liftIO $ do
    sh <- readTVarIO tsh
    st <- readTVarIO tst
    o <- readTVarIO to
    let enoughSpaceP = ship_freeSpace sh >= weight bw * fromIntegral ba
    let enoughMoneyP = owner_money o >= stockSellPrice st bw * fromIntegral ba
    let enoughWareP = enoughWare bw ba st
    return $ and [enoughSpaceP, enoughMoneyP, enoughWareP] 

buy :: Ware -> Amount -> ReaderT TradeContext IO ()
buy bw ba = do
  (to, tsh, tst) <- ask
  st <- liftIO $ readTVarIO tst
  cb <- canBuy bw ba

  liftIO $
    if cb then atomically $ do
            stmRemoveWare bw ba tst
            stmAddWare bw ba tsh
            stmRemoveMoney (stockSellPrice st bw * fromIntegral ba) to
            stmAddMoney (stockSellPrice st bw * fromIntegral ba) tst
          else return ()

canSell :: Ware -> Amount -> ReaderT TradeContext IO Bool
canSell sw sa = do
  (to, tsh, tst) <- ask
  liftIO $ do
    o <- readTVarIO to
    sh <- readTVarIO tsh
    st <- readTVarIO tst
    let enoughMoneyP = station_money st >= stockBuyPrice st sw * fromIntegral sa
    let enoughWareP = enoughWare sw sa sh

    return $ and [enoughMoneyP, enoughWareP] 

sell :: Ware -> Amount -> ReaderT TradeContext IO ()
sell sw sa = do
  (to, tsh, tst) <- ask
  st <- liftIO $ readTVarIO tst
  cs <- canSell sw sa

  liftIO $
    if cs then atomically $ do
            stmRemoveWare sw sa tsh
            stmAddWare sw sa tst
            stmRemoveMoney (stockBuyPrice st sw * fromIntegral sa) tst
            stmAddMoney (stockBuyPrice st sw * fromIntegral sa) to
          else return ()

-- Following 2 fns are named counter-intuitive, since only one is invasive
-- still, I think their return types go well with their names
-- but anyways, these should be regarded as utility
stmPerform :: (a -> b) -> (TVar a) -> STM b
stmPerform fn tobj = readTVar tobj >>= return . fn

stmPerform_ :: (a -> a) -> (TVar a) -> STM ()
stmPerform_ fn tobj = readTVar tobj >>= (writeTVar tobj) . fn

-- WareOps for STM'ed instances of WareOps
stmCheckWare :: (WareOps a) => Ware -> (TVar a) -> STM Amount
stmCheckWare w = stmPerform (checkWare w)

stmEnoughWare :: (WareOps a) => Ware -> Amount -> (TVar a) -> STM Bool
stmEnoughWare w a = stmPerform (enoughWare w a)

stmAddWare :: (WareOps a) => Ware -> Amount -> (TVar a) -> STM ()
stmAddWare w a = stmPerform_ (addWare w a)

stmRemoveWare :: (WareOps a) => Ware -> Amount -> (TVar a) -> STM ()
stmRemoveWare w a = stmPerform_ (removeWare w a)

-- MoneyOps for STM'ed instances of MoneyOps
stmAddMoney :: (MoneyOps a) => Amount -> (TVar a) -> STM ()
stmAddMoney a = stmPerform_ (addMoney a)

stmRemoveMoney :: (MoneyOps a) => Amount -> (TVar a) -> STM ()
stmRemoveMoney a = stmPerform_ (removeMoney a)
