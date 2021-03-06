
module NavigationIO where

import Control.Concurrent.STM
import Control.Monad.Reader
import Data.Function (on)
import qualified Data.IntMap as I
import Data.List (sortBy)

import Auxiliary.Graph
import Auxiliary.Transactions
import Contexts
import Data.Jumpgates
import DataTypes
import GlobalConst (const_jg_exit_radius)
import Jumpgates
import Navigation
import ShipStats
import Space
import Vector

setShipOnCourse :: (TVar Ship) -> (TVar Station) -> STM ()
setShipOnCourse tsh tst = do
  from <- readTVar tsh >>= return . nav_pos_vec . spacePosition
  to <- readTVar tst >>= return . nav_pos_vec . spacePosition
  topSpeed <- readTVar tsh >>= return . shipStats_topSpeed . ship_stats
  setNavStatus tsh (MovingToSpace (computeVelocity topSpeed from to) to)

setNavStatus :: (TVar Ship) -> NavStatus -> STM ()
setNavStatus tsh ns = readTVar tsh >>= \sh ->
  writeTVar tsh sh{ ship_navModule =
    (ship_navModule sh){ navModule_status = ns } }

setNavPosition :: (TVar Ship) -> ShipNavPosition -> STM ()
setNavPosition tsh snp = readTVar tsh >>= \sh ->
  writeTVar tsh sh{ ship_navModule =
    (ship_navModule sh){ navModule_position = snp } }

setNavProgramPure :: NavProgram -> Ship -> Ship
setNavProgramPure prg sh =
  let nm = ship_navModule sh
  in  sh{ ship_navModule = nm{ navModule_program = prg } }

startDockingTo :: (TVar Ship) -> (TVar Station) -> STM ()
startDockingTo tsh tst = setNavStatus tsh (DockingToStation tst)

startUndocking :: (TVar Ship) -> STM ()
startUndocking tsh = setNavStatus tsh Undocking

-- Randomly choose a spot inside a r-circle around p, but not p
-- it's gonna use IO later, hence the type. TODO implement pseudorandom choice
randomizeAround :: NavPosition -> Double -> IO NavPosition
randomizeAround (Space (Vector3D x y z) t) _ = return $
  Space (Vector3D (x + 1/10) (y + 1/10) (z + 1/10)) t

departureAround :: NavPosition -> NavPosition
departureAround (Space (Vector3D x y z) t) =
  Space (Vector3D (x + 1/10) (y + 1/10) (z + 1/10)) t

jump :: Jumpgate -> SpaceType -> IO ShipNavPosition
jump jg stype = 
  case stype of
    Hyperspace -> return $ OnJumpgate jg
    Normalspace -> 
      randomizeAround (jg_normal jg) const_jg_exit_radius >>= return . SNPSpace

closestJumpgate :: ShipNavPosition -> ReaderT NavContext STM Jumpgate
closestJumpgate p@(SNPSpace (Space v t)) =
  ask >>= lift . readTVar . nc_jumpgates >>= return . head . (sortBy sortFn) . I.elems
  where sortFn = compare `on` (\jg -> distance v (jg_vector jg t))
closestJumpgate (InHyperspaceBetween (jg1, d1) (jg2, d2)) =
  if d1 <= d2 
    then return jg1
    else return jg2
closestJumpgate (OnJumpgate jg) = return jg

closestJumpgateNP :: NavPosition -> ReaderT NavContext STM Jumpgate
closestJumpgateNP np = closestJumpgate (SNPSpace np)

stationRoutePlanner :: ShipNavPosition -> TVar Station -> ReaderT NavContext STM NavProgram
stationRoutePlanner np tst = do
  pos <- lift $ checkT spacePosition tst
  rt <- smartRoutePlanner np pos
  return $ rt ++ [NA_Dock tst]

smartRoutePlanner :: ShipNavPosition -> NavPosition -> ReaderT NavContext STM NavProgram
smartRoutePlanner (SNPSpace p1@(Space v1 t1)) p2@(Space v2 t2)
  | and [t1 == t2, t1 == Normalspace] = do
    jg1 <- closestJumpgateNP p1
    jg2 <- closestJumpgateNP p2
    if jg1 == jg2
      then return [ NA_MoveTo v2 ]
      else return $ 
             [ NA_MoveTo (jg_vector jg1 Normalspace)
             , NA_Jump Hyperspace ]
             ++ (jgRoutePlanner jg1 jg2) ++
             [ NA_Jump Normalspace
             , NA_MoveTo v2 ]
  | otherwise = error "Traveling in hyperspace is restricted to jumpgates " -- TODO
smartRoutePlanner (DockedToStation tst) p2@(Space v2 t2) =
  lift (readTVar tst) >>= \st -> smartRoutePlanner (SNPSpace (spacePosition st)) p2  
--  | and [t1 == t2, t1 == Hyperspace] = return [NA_MoveTo v2]
--  | t1 == Hyperspace = closestJumpgate p2 >>= \jg -> 
--    return
--     [ NA_MoveTo (jg_vector jg Hyperspace)
--     , NA_Jump Normalspace
--     , NA_MoveTo v2 ]
--  | t1 == Normalspace = closestJumpgate p1 >>= \jg -> 
--    return
--      [ NA_MoveTo (jg_vector jg Normalspace)
--      , NA_Jump Hyperspace
--      , NA_MoveTo v2 ]

jgRoutePlanner :: Jumpgate -> Jumpgate -> NavProgram
jgRoutePlanner jg1 jg2 =
  let routes = findRoutes jg1 jg2
      sumDistance route =  sum $ map (uncurry jgsDistance) (zip route (tail route))
      shortest =
        if null routes
          then error $ "NavigationIO: jgRoutePlanner: can't find a route " ++
                 "from " ++ show jg1 ++ " to " ++ show jg2
          else head $ sortBy (on compare sumDistance) routes
  in map NA_MoveInHyper (tail shortest)
  

tickNavProgram :: Ship -> ReaderT NavContext STM Ship
tickNavProgram sh
  | null (navModule_program $ ship_navModule sh) = return sh
  | otherwise = do
    let nm = ship_navModule sh
    let (p:ps) = navModule_program nm
    let stat = navModule_status nm
    let topSpeed = shipStats_topSpeed $ ship_stats sh
    (ns, np) <- 
      case p of
        (NA_MoveTo v) ->
          let diff = v - (nav_pos_vec $ spacePosition $ navModule_position nm) 
              velo = makeLength topSpeed diff
          in             return (MovingToSpace velo v, ps)
        (NA_Dock tst) -> return (DockingToStation tst, ps)
        NA_Undock     -> return (Undocking           , ps)
        (NA_Jump st)  -> closestJumpgate (navModule_position nm) >>=
          \jg -> return (Jumping (JE_Jumpgate jg) st , ps)
        (NA_MoveInHyper jg)
                      -> return (MovingInHyperspace topSpeed jg, ps)
    case stat of
      Idle -> return sh{ ship_navModule = 
                         nm { navModule_status = ns
                            , navModule_program = np } }
      otherwise -> return sh

setNavProgram :: (TVar Ship) -> NavProgram -> STM ()
setNavProgram tsh prg = modifyT (setNavProgramPure prg) tsh

