{-# LANGUAGE PackageImports #-}

module Propellor.Property where

import System.Directory
import System.FilePath
import Control.Monad
import Data.Monoid
import Control.Monad.IfElse
import "mtl" Control.Monad.RWS.Strict

import Propellor.Types
import Propellor.Info
import Propellor.Engine
import Utility.Monad

-- Constructs a Property.
property :: Desc -> Propellor Result -> Property
property d s = mkProperty d s mempty mempty

-- | Combines a list of properties, resulting in a single property
-- that when run will run each property in the list in turn,
-- and print out the description of each as it's run. Does not stop
-- on failure; does propigate overall success/failure.
propertyList :: Desc -> [Property] -> Property
propertyList desc ps = mkProperty desc (ensureProperties ps) mempty ps

-- | Combines a list of properties, resulting in one property that
-- ensures each in turn. Stops if a property fails.
combineProperties :: Desc -> [Property] -> Property
combineProperties desc ps = mkProperty desc (go ps NoChange) mempty ps
  where
	go [] rs = return rs
	go (l:ls) rs = do
		r <- ensureProperty l
		case r of
			FailedChange -> return FailedChange
			_ -> go ls (r <> rs)

-- | Combines together two properties, resulting in one property
-- that ensures the first, and if the first succeeds, ensures the second.
-- The property uses the description of the first property.
before :: Property -> Property -> Property
p1 `before` p2 = p2 `requires` p1
	`describe` (propertyDesc p1)

-- | Makes a perhaps non-idempotent Property be idempotent by using a flag
-- file to indicate whether it has run before.
-- Use with caution.
flagFile :: Property -> FilePath -> Property
flagFile p = flagFile' p . return

flagFile' :: Property -> IO FilePath -> Property
flagFile' p getflagfile = adjustProperty p $ \satisfy -> do
	flagfile <- liftIO getflagfile
	go satisfy flagfile =<< liftIO (doesFileExist flagfile)
  where
	go _ _ True = return NoChange
	go satisfy flagfile False = do
		r <- satisfy
		when (r == MadeChange) $ liftIO $ 
			unlessM (doesFileExist flagfile) $ do
				createDirectoryIfMissing True (takeDirectory flagfile)
				writeFile flagfile ""
		return r

--- | Whenever a change has to be made for a Property, causes a hook
-- Property to also be run, but not otherwise.
onChange :: Property -> Property -> Property
p `onChange` hook = mkProperty (propertyDesc p) satisfy (propertyInfo p) cs
  where
	satisfy = do
		r <- ensureProperty p
		case r of
			MadeChange -> do
				r' <- ensureProperty hook
				return $ r <> r'
			_ -> return r
	cs = propertyChildren p ++ [hook]

(==>) :: Desc -> Property -> Property
(==>) = flip describe
infixl 1 ==>

-- | Makes a Property only need to do anything when a test succeeds.
check :: IO Bool -> Property -> Property
check c p = adjustProperty p $ \satisfy -> ifM (liftIO c)
	( satisfy
	, return NoChange
	)

-- | Tries the first property, but if it fails to work, instead uses
-- the second.
fallback :: Property -> Property -> Property
fallback p1 p2 = mkProperty (propertyDesc p1) satisfy (propertyInfo p1) cs
  where
	cs = p2 : propertyChildren p1
	satisfy = do
		r <- propertySatisfy p1
		if r == FailedChange
			then propertySatisfy p2
			else return r

-- | Marks a Property as trivial. It can only return FailedChange or
-- NoChange. 
--
-- Useful when it's just as expensive to check if a change needs
-- to be made as it is to just idempotently assure the property is
-- satisfied. For example, chmodding a file.
trivial :: Property -> Property
trivial p = adjustProperty p $ \satisfy -> do
	r <- satisfy
	if r == MadeChange
		then return NoChange
		else return r

doNothing :: Property
doNothing = property "noop property" noChange

-- | Makes a property that is satisfied differently depending on the host's
-- operating system. 
--
-- Note that the operating system may not be declared for some hosts.
withOS :: Desc -> (Maybe System -> Propellor Result) -> Property
withOS desc a = property desc $ a =<< getOS

-- | Undoes the effect of a property.
revert :: RevertableProperty -> RevertableProperty
revert (RevertableProperty p1 p2) = RevertableProperty p2 p1

-- | Changes the action that is performed to satisfy a property. 
adjustProperty :: Property -> (Propellor Result -> Propellor Result) -> Property
adjustProperty p f = mkProperty
	(propertyDesc p)
	(f (propertySatisfy p))
	(propertyInfo p)
	(propertyChildren p)

makeChange :: IO () -> Propellor Result
makeChange a = liftIO a >> return MadeChange

noChange :: Propellor Result
noChange = return NoChange

-- | Registers an action that should be run at the very end,
endAction :: Desc -> (Result -> Propellor Result) -> Propellor ()
endAction desc a = tell [EndAction desc a]
