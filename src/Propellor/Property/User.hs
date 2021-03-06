module Propellor.Property.User where

import System.Posix

import Propellor

data Eep = YesReallyDeleteHome

accountFor :: UserName -> Property NoInfo
accountFor user = check (isNothing <$> catchMaybeIO (homedir user)) $ cmdProperty "adduser"
	[ "--disabled-password"
	, "--gecos", ""
	, user
	]
	`describe` ("account for " ++ user)

-- | Removes user home directory!! Use with caution.
nuked :: UserName -> Eep -> Property NoInfo
nuked user _ = check (isJust <$> catchMaybeIO (homedir user)) $ cmdProperty "userdel"
	[ "-r"
	, user
	]
	`describe` ("nuked user " ++ user)

-- | Only ensures that the user has some password set. It may or may
-- not be a password from the PrivData.
hasSomePassword :: UserName -> Property HasInfo
hasSomePassword user = hasSomePassword' user hostContext

-- | While hasSomePassword uses the name of the host as context,
-- this allows specifying a different context. This is useful when
-- you want to use the same password on multiple hosts, for example.
hasSomePassword' :: IsContext c => UserName -> c -> Property HasInfo
hasSomePassword' user context = check ((/= HasPassword) <$> getPasswordStatus user) $
	hasPassword' user context

-- | Ensures that a user's password is set to a password from the PrivData.
-- (Will change any existing password.)
--
-- A user's password can be stored in the PrivData in either of two forms;
-- the full cleartext <Password> or a <CryptPassword> hash. The latter
-- is obviously more secure.
hasPassword :: UserName -> Property HasInfo
hasPassword user = hasPassword' user hostContext

hasPassword' :: IsContext c => UserName -> c -> Property HasInfo
hasPassword' user context = go `requires` shadowConfig True
  where
	go = withSomePrivData srcs context $
		property (user ++ " has password") . setPassword
	srcs =
		[ PrivDataSource (CryptPassword user)
			"a crypt(3)ed password, which can be generated by, for example: perl -e 'print crypt(shift, q{$6$}.shift)' 'somepassword' 'somesalt'"
		, PrivDataSource (Password user) ("a password for " ++ user)
		]

setPassword :: (((PrivDataField, PrivData) -> Propellor Result) -> Propellor Result) -> Propellor Result
setPassword getpassword = getpassword $ go
  where
	go (Password user, password) = set user password []
	go (CryptPassword user, hash) = set user hash ["--encrypted"]
	go (f, _) = error $ "Unexpected type of privdata: " ++ show f

	set user v ps = makeChange $ withHandle StdinHandle createProcessSuccess
		(proc "chpasswd" ps) $ \h -> do
			hPutStrLn h $ user ++ ":" ++ v
			hClose h

lockedPassword :: UserName -> Property NoInfo
lockedPassword user = check (not <$> isLockedPassword user) $ cmdProperty "passwd"
	[ "--lock"
	, user
	]
	`describe` ("locked " ++ user ++ " password")

data PasswordStatus = NoPassword | LockedPassword | HasPassword
	deriving (Eq)

getPasswordStatus :: UserName -> IO PasswordStatus
getPasswordStatus user = parse . words <$> readProcess "passwd" ["-S", user]
  where
	parse (_:"L":_) = LockedPassword
	parse (_:"NP":_) = NoPassword
	parse (_:"P":_) = HasPassword
	parse _ = NoPassword

isLockedPassword :: UserName -> IO Bool
isLockedPassword user = (== LockedPassword) <$> getPasswordStatus user

homedir :: UserName -> IO FilePath
homedir user = homeDirectory <$> getUserEntryForName user

hasGroup :: UserName -> GroupName -> Property NoInfo
hasGroup user group' = check test $ cmdProperty "adduser"
	[ user
	, group'
	]
	`describe` unwords ["user", user, "in group", group']
  where
	test = not . elem group' . words <$> readProcess "groups" [user]

-- | Controls whether shadow passwords are enabled or not.
shadowConfig :: Bool -> Property NoInfo
shadowConfig True = check (not <$> shadowExists) $
	cmdProperty "shadowconfig" ["on"]
		`describe` "shadow passwords enabled"
shadowConfig False = check shadowExists $
	cmdProperty "shadowconfig" ["off"]
		`describe` "shadow passwords disabled"

shadowExists :: IO Bool
shadowExists = doesFileExist "/etc/shadow"
