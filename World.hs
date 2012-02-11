module World where

import Control.Concurrent.STM hiding (check)
import Control.Monad (forM)
import Control.Monad.Reader
import Data.IntMap hiding (filter, map)         -- to avoid confusion when
import qualified Data.IntMap as I (filter, map) -- using filter and map,
import Prelude hiding (filter, map)             -- I import them qualified,
import qualified Prelude as P (filter, map)     -- 'cuz it cost me 20 minutes once
import Data.List (foldl') -- non-alphabetical so that I could write the above comment
import System.Posix (sleep)

import AI
import Currency
import GlobalConst
import IntMapAux
import Navigation
import Owners
import Ships hiding (Ships(..))
import Stations hiding (Stations(..))
import Transactions
import qualified Vector as V
import Wares
import Wrappers

-- File contents, [INDEX] stands for `search for the bracketed word 
--                                  to get to the section mentioned`
--
-- [WORLD] - World data type, function for creating it,
--           wrappers for `global` IntMaps and some auxiliary functions
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

data World = World
    { world_stations :: TVar (IntMap (TVar Station)) 
    , world_ships :: TVar (IntMap (TVar Ship)) 
    , world_owners :: TVar (IntMap (TVar Owner)) 
    } deriving ()

type Owners = TVar (IntMap (TVar Owner))
type Ships = TVar (IntMap (TVar Ship))
type Stations = TVar (IntMap (TVar Station))

makeNewWorld :: Owner -> Ship -> IO World
makeNewWorld owner ship = do
    tStations <- newTVarIO empty
    atomically $ intMapToTVarIntMap defaultStations >>= writeTVar tStations

    tShips <- newTVarIO empty
    addInstance tShips ship -- adds the player character's ship
    atomically $ intMapToTVarIntMap defaultShips >>= writeTVar tShips 

    tOwners <- newTVarIO empty
    addInstance tOwners owner -- adds the player character
    atomically $ intMapToTVarIntMap defaultOwners >>= writeTVar tOwners

    fillOwnedShips tShips tOwners -- adds owned ships IDs to owner_shipsOwned
    dockMissing tShips tStations -- docks the ships that start docked

    return $ World tStations tShips tOwners

intMapToTVarIntMap :: IntMap a -> STM (IntMap (TVar a))
intMapToTVarIntMap ias = mapM newTVar vals >>= return . fromList . (zip keys)
                         where keys = P.map fst (toList ias)
                               vals = P.map snd (toList ias)

          -- stop lock
gameCycle :: TVar Bool -> ReaderT World IO ()
gameCycle lock = liftIO (sleep (fromIntegral tickReal))
         >> cycleEverything
      -- >> printWorld
         >> (liftIO $ readTVarIO lock)
         >>= \stop -> if (not stop) then gameCycle lock
                                    else return ()

gameCycleIO :: World -> TVar Bool -> IO ()
gameCycleIO w lock = runReaderT (gameCycle lock) w


-- SECTION BREAK
-- [GLOBTVAR] -- see section description in the contents above

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
    liftIO $ cycleClass owners
    liftIO $ cycleClass stations 
    liftIO $ cycleClass ships 
    liftIO $ processDocking ships stations
    liftIO $ processUndocking ships stations

printWorld :: ReaderT World IO ()
printWorld = do
    world <- ask
    liftIO $ putStrLn "\n\nShowing stations:"
    liftIO $ printClass (world_stations world)
    liftIO $ putStrLn "\n\nShowing ships:"
    liftIO $ printClass (world_ships world)
    liftIO $ putStrLn "\n\nShowing owners:"
    liftIO $ printClass (world_owners world)


-- SECTION BREAK
-- [PRINT] -- see section description in the contents above

printClass :: (Show a) => TVar (IntMap (TVar a)) -> IO ()
printClass tmap = readTVarIO tmap >>=
    (mapM readTVarIO) . (P.map snd) . toList >>= mapM_ print 


-- SECTION BREAK
-- [PROCESS] -- see section description in the contents above

class Processable a where
    process :: Int -> IntMap (TVar a) -> IO ()

instance Processable Station where
    process sId ss = atomically $
        readTVar (ss ! sId) >>= \station ->
        writeTVar (ss ! sId) $ stationFns station
        where stationFns = foldl' (.) id
                                  [ (\st -> addMoney 3000 st) -- example tax income
                                  ]

instance Processable Owner where
    process _ _ = return ()

instance Processable Ship where
    process _ _ = return ()

cycleClass :: (Processable a) => TVar (IntMap (TVar a)) -> IO ()
cycleClass timap = readTVarIO timap >>= \imap -> 
                                 mapM_ (\k -> process k imap) (keys imap)

fillOwnedShips :: Ships -> Owners -> IO ()
fillOwnedShips sh o = atomically $ do
    ships <- readTVar sh
    pairs <- mapM readTVar (shVals ships) >>= 
                        return . (zip (shKeys ships)) . (P.map ship_owner) 
    owners <- readTVar o
    mapM_ (\(sid,oid) -> readTVar (owners ! oid) >>= \own ->
              writeTVar (owners ! oid) own{ owner_shipsOwned = 
                if sid `notElem` (owner_shipsOwned own) then
                                                owner_shipsOwned own ++ [sid]
                                                        else
                                                owner_shipsOwned own})
          pairs
    where shKeys ships = P.map fst (toList ships)
          shVals ships = P.map snd (toList ships)
    
dockMissing :: Ships -> Stations -> IO ()
dockMissing tships tstations = atomically $ do
    ships <- readTVar tships
    stations <- readTVar tstations
    needDocking <- filterM (\k -> check ships k docked) (keys ships)
    dockingStations <- forM needDocking (\k -> check ships k dockedStID)
    let dockingPairs = zip needDocking dockingStations
    mapM_ (\(shid,stid) -> dockShSt (ships ! shid) shid (stations ! stid) stid) dockingPairs

processDocking :: Ships -> Stations -> IO ()
processDocking tships tstations = atomically $ do
    ships <- readTVar tships
    stations <- readTVar tstations
    needDocking <- filterM (\k -> check ships k docking) (keys ships)
    dockingStations <- forM needDocking (\k -> check ships k dockingStID)
    let dockingPairs = zip needDocking dockingStations
    mapM_ (\(shid,stid) -> dockShSt (ships ! shid) shid (stations ! stid) stid) dockingPairs

dockShSt :: (TVar Ship) -> Int -> (TVar Station) -> Int -> STM ()
dockShSt tsh shid tst stid = do
    ship <- readTVar tsh
    writeTVar tsh ship{ ship_navModule = NavModule (DockedToStation stid) Idle }
    station <- readTVar tst
    writeTVar tst station{ station_dockingBay =
                            if shid `notElem` (station_dockingBay station)
                                    then  (station_dockingBay station) ++ [shid] 
                                    else station_dockingBay station }

processUndocking :: Ships -> Stations -> IO ()
processUndocking tships tstations = atomically $ do
    ships <- readTVar tships
    stations <- readTVar tstations
    needUndocking <- filterM (\k -> check ships k undocking) (keys ships)
    undockingStations <- forM needUndocking (\k -> check ships k dockingStID)
    let undockingPairs = zip needUndocking undockingStations
    mapM_ (\(shid,stid) -> undockShSt (ships ! shid) shid (stations ! stid) stid) undockingPairs

undockShSt :: (TVar Ship) -> Int -> (TVar Station) -> Int -> STM ()
undockShSt tsh shid tst stid = do
    ship <- readTVar tsh
    station <- readTVar tst
    let departure = V.fromList [0.1, 0.1, 0.1] -- magic constant FIXME
    let stationPos = nav_pos_vec (station_position station)
    let newShipNavModule = NavModule (SNPSpace $ Space (stationPos + departure) 
                                                 Normalspace) 
                                     Idle 
    writeTVar tsh ship{ ship_navModule = newShipNavModule }
    writeTVar tst station{ station_dockingBay =
                            P.filter (/= shid) (station_dockingBay station) }

processAI :: ShipAI -> ShipID -> ReaderT World IO ShipAI -- this fn does more than its 
processAI ai@(ShipAI (SGo stid) ais) shid = do     -- type signature shows, care
    world <- ask
    ships <- liftIO $ readTVarIO $  world_ships world
    stations <- liftIO $ readTVarIO $ world_stations world
    satisfied <- liftIO $ readTVarIO (ships ! shid) >>= return . (flip dockedToSt stid)
    if satisfied then return $ next ai
                 else return ai
processAI ai@(ShipAI (SBuy bw ba) ais) shid = do
    world <- ask

    ships <- liftIO $ readTVarIO $  world_ships world
    let tsh = ships ! shid
    sh <- liftIO $ readTVarIO tsh

    stations <- liftIO $ readTVarIO $ world_stations world
    let tst = stations ! (dockedStID sh)
    st <- liftIO $ readTVarIO tst

    owners <- liftIO $ readTVarIO $ world_owners world
    let to = owners ! (ship_owner sh)
    o <- liftIO $ readTVarIO to

    let enoughSpaceP = ship_freeSpace sh >= weight bw * fromIntegral ba
    let enoughMoneyP = owner_money o >= station_wareCost st bw * fromIntegral ba
    let enoughWareP = enoughWare bw ba st

    if and [enoughSpaceP, enoughMoneyP, enoughWareP] 
        then liftIO $ atomically $ do
            stmRemoveWare bw ba tst
            stmAddWare bw ba tsh
            stmRemoveMoney (station_wareCost st bw * fromIntegral ba) to
            stmAddMoney (station_wareCost st bw * fromIntegral ba) tst
            return $ next ai
        else return ai
processAI ai@(ShipAI (SSell sw sa) ais) shid = do
    world <- ask

    ships <- liftIO $ readTVarIO $  world_ships world
    let tsh = ships ! shid
    sh <- liftIO $ readTVarIO tsh

    stations <- liftIO $ readTVarIO $ world_stations world
    let tst = stations ! (dockedStID sh)
    st <- liftIO $ readTVarIO tst

    owners <- liftIO $ readTVarIO $ world_owners world
    let to = owners ! (ship_owner sh)
    o <- liftIO $ readTVarIO to

    let enoughMoneyP = station_money st >= station_wareCost st sw * fromIntegral sa
    let enoughWareP = enoughWare sw sa sh

    if and [enoughMoneyP, enoughWareP] 
        then liftIO $ atomically $ do
            stmRemoveWare sw sa tsh
            stmAddWare sw sa tst
            stmRemoveMoney (station_wareCost st sw * fromIntegral sa) tst
            stmAddMoney (station_wareCost st sw * fromIntegral sa) to
            return $ next ai
        else if enoughWareP then return $ next ai -- if AI doesn't have the cargo,
                            else return ai -- it should move on to its next task
                       -- otherwise it should wait for station to get enough money
processAI _ _ = undefined

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
