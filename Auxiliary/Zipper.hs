
module Auxiliary.Zipper where

data Zipper a = Zipper
  { zip_current :: a
  , zip_others :: [a]
  }
  deriving (Eq, Show)

rotate :: Zipper a -> Zipper a
rotate (Zipper a (b:as)) = Zipper b (as ++ [a])

fromList :: [a] -> Zipper a
fromList [] = error "Zipper: can't make a Zipper from an empty list"
fromList (p:ps) = Zipper p ps

toList :: Zipper a -> [a]
toList (Zipper z zs) = z:zs

selectBy :: Zipper a -> (a -> Bool) -> Zipper a
selectBy (Zipper z zs) f
    | length (filter f (z:zs)) > 1 = error "FA selectBy: more than one match"
    | length (filter f (z:zs)) == 0 = error "FA selectBy: state not found"
    | otherwise = 
        let t = head $ filter f (z:zs)
        in Zipper t (filter (not . f) (z:zs))

select :: (Eq a) => Zipper a -> a -> Zipper a
select z a = selectBy z (==a)

