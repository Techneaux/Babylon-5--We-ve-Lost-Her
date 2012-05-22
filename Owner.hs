module Owner where

import Data.IntMap

import Currency
import DataTypes
import InterfaceShow
import PersonalData
import Wrappers

instance Show Owner where
    show t = show (owner_name t)

instance ContextualShow Owner where
    contextShow (c, ScreenCharacter) o = "The main character.\nName: " ++ owner_name o
        ++ "\n" ++ contextShow (c, ScreenCharacter) (owner_personalInfo o)
        ++ "\nMoney: " ++ show (owner_money o)

instance ContextualShow PersonalInfo where
    contextShow (_, ScreenCharacter) (Person r c) = show r ++ " " ++ show c

ownerOne :: Owner
ownerOne = Owner "Helen Ripley" [] [] defaultPersonalInfo 1000

defaultOwners = fromList $ zip [1..] [ownerOne]

defaultPersonalInfo = Person Human Military

instance MoneyOps Owner where
    addMoney m o@Owner{ owner_money = om } = o{ owner_money = om + m}
    enoughMoney m o@Owner{ owner_money = om } = om >= m

