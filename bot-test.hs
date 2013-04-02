import Data.List
import Data.Maybe
import Network
--import System.CPUTime
import System.Directory
import System.IO
import System.IO.Error
import System.Exit
import Control.Arrow
import Control.Monad.Reader
import Control.Exception
import Text.Printf
--import Text.Regex.TDFA
import Prelude

--import NLP.Nerf
import NLP.WordNet
import NLP.WordNet.Prims (getIndexString, indexLookup, indexToSenseKey, getSynsetForSense, senseCount, getSynset, getWords, getGloss)
import NLP.WordNet.PrimTypes

wndir  = "/usr/share/wordnet/dict/"
server = "irc.freenode.org"
port   = 6667
chan   = "#lolbots"
nick   = "wordnetbot"
owner  = "shadowdaemon"

-- The 'Net' monad, a wrapper over IO, carrying the bot's immutable state.
type Net = ReaderT Bot IO
data Bot = Bot { socket :: Handle, wne :: WordNetEnv }

-- Set up actions to run on start and end, and run the main loop.
main :: IO ()
main = bracket connect disconnect loop
  where
    disconnect = do hClose . socket ; closeWordNet . wne
    loop st    = catchIOError (runReaderT run st) (const $ return ())

-- Connect to the server and return the initial bot state.  Initialize WordNet.
connect :: IO Bot
connect = notify $ do
    h <- connectTo server (PortNumber (fromIntegral port))
    w <- initializeWordNetWithOptions (return wndir :: Maybe FilePath) 
      (Just (\e f -> putStrLn (e ++ show (f :: SomeException))))
    hSetBuffering h NoBuffering
    return (Bot h w)
  where
    notify a = bracket_
        (printf "Connecting to %s ... " server >> hFlush stdout)
        (putStrLn "done.")
        a

-- We're in the Net monad now, so we've connected successfully.
-- Join a channel, and start processing commands.
run :: Net ()
run = do
    write "NICK" nick
    write "USER" (nick++" 0 * :user")
    write "JOIN" chan
    asks socket >>= listen

-- Process each line from the server (this needs flood prevention somewhere).
listen :: Handle -> Net ()
listen h = forever $ do
    s <- init `fmap` io (hGetLine h)
    io (putStrLn s)
    if ping s then pong s else processLine (words s)
  where
    forever a = a >> forever a
    ping x    = "PING :" `isPrefixOf` x
    pong x    = write "PONG" (':' : drop 6 x)

-- Get the actual message.
getMsg :: [String] -> [String]
getMsg a
    | (head $ drop 1 a) == "PRIVMSG" = (drop 1 (a!!3)) : (drop 4 a)
    | otherwise = []

-- Who is speaking to us?
getNick :: [String] -> String
getNick = drop 1 . takeWhile (/= '!') . head

-- Which channel is message coming from?  Also could be private message.
getChannel :: [String] -> String
getChannel = head . drop 2

-- Are we being spoken to?
spokenTo :: [String] -> Bool
spokenTo []              = False
spokenTo a
    | b == nick          = True
    | b == (nick ++ ":") = True
    | otherwise          = False
  where
    b = (head a)

-- Is this a private message?
isPM :: [String] -> Bool
isPM a
    | getChannel a == nick = True
    | otherwise            = False

-- Process IRC line.
processLine :: [String] -> Net ()
processLine a
    | length a == 0     = return ()
    | length msg' == 0  = return () -- Ignore because not PRIVMSG.
    | chan' == nick     = if (head $ head msg') == '!' then evalCmd chan' who' msg' -- Evaluate command.
                          else reply [] who' msg' -- Respond to PM.
    | spokenTo msg'     = if (head $ head $ tail msg') == '!' then evalCmd chan' who' (tail msg') -- Evaluate command.
                          else reply chan' who' (tail msg') -- Respond upon being addressed.
--    | otherwise         = processMsg chan' who' msg' -- Process message.
    | otherwise         = reply chan' [] msg' -- Testing.
  where
    msg' = getMsg a
    who' = getNick a
    chan' = getChannel a

-- Reply to message.
reply :: String -> String -> [String] -> Net ()
reply [] who' msg = privMsg who' $ reverse $ unwords msg
reply chan' [] msg  = chanMsg chan' $ reverse $ unwords msg
reply chan' who' msg = replyMsg chan' who' $ reverse $ unwords msg -- Cheesy reverse gimmick, for testing.

-- Process messages.
--processMsg :: String -> String -> [String] -> ReaderT Bot IO ()
--processMsg chan' who' msg' =

-- Evaluate commands.
evalCmd :: String -> String -> [String] -> Net ()
evalCmd _ b (x:xs) | x == "!quit"       = if b == owner then write "QUIT" ":Exiting" >> io (exitWith ExitSuccess) else return ()
evalCmd _ _ (x:xs) | x == "!search"     = wnSearchTest2 (head xs)
evalCmd _ _ (x:xs) | x == "!hypernym"   = wnSearchHypernymTest1 (head xs)
evalCmd _ _ (x:xs) | x == "!overview"   = wnOverviewTest (head xs)
evalCmd _ _ (x:xs) | x == "!type"       = wnWordTypeTest (head xs)
evalCmd a b (x:xs) | x == "!words"      = wnGetWordsTest3 (head xs) >>= replyMsg a b
evalCmd _ _ _                           = return ()

-- Send a message to the channel.
chanMsg :: String -> String -> Net ()
chanMsg chan' msg = write "PRIVMSG" (chan' ++ " :" ++ msg)

-- Send a reply message.
replyMsg :: String -> String -> String -> Net ()
replyMsg chan' nick' msg = write "PRIVMSG" (chan' ++ " :" ++ nick' ++ ": " ++ msg)

-- Send a private message.
privMsg :: String -> String -> Net ()
privMsg nick' msg = write "PRIVMSG" (nick' ++ " :" ++ msg)

-- Send a message out to the server we're currently connected to.
write :: String -> String -> Net ()
write s t = do
    h <- asks socket
    io $ hPrintf h "%s %s\r\n" s t
    io $ printf    "> %s %s\n" s t

-- Convenience.
io :: IO a -> Net a
io = liftIO

-- Replace items in list.
replace :: Eq a => a -> a -> [a] -> [a]
replace _ _ [] = []
replace a b (x:xs)
    | x == a    = b : replace a b xs
    | otherwise = x : replace a b xs

wnTypeString :: String -> Net String
wnTypeString a = do
    w <- asks wne
    ind1 <- io $ indexLookup w a Noun
    ind2 <- io $ indexLookup w a Verb
    ind3 <- io $ indexLookup w a Adj
    ind4 <- io $ indexLookup w a Adv
    return (type' ((count' ind1) : (count' ind2) : (count' ind3) : (count' ind4) : []))
  where
    count' a = if isJust a then senseCount (fromJust a) else 0
    type' [] = "Other"
    type' a
      | fromJust (elemIndex (maximum a) a) == 0 = "Noun"
      | fromJust (elemIndex (maximum a) a) == 1 = "Verb"
      | fromJust (elemIndex (maximum a) a) == 2 = "Adj"
      | fromJust (elemIndex (maximum a) a) == 3 = "Adv"
      | otherwise                               = "Other"

wnTypePOS :: String -> Net POS
wnTypePOS a = do
    w <- asks wne
    ind1 <- io $ indexLookup w a Noun
    ind2 <- io $ indexLookup w a Verb
    ind3 <- io $ indexLookup w a Adj
    ind4 <- io $ indexLookup w a Adv
    return (type' ((count' ind1) : (count' ind2) : (count' ind3) : (count' ind4) : []))
  where
    count' a = if isJust a then senseCount (fromJust a) else 0
    type' [] = Verb
    type' a
      | fromJust (elemIndex (maximum a) a) == 0 = Noun
      | fromJust (elemIndex (maximum a) a) == 1 = Verb
      | fromJust (elemIndex (maximum a) a) == 2 = Adj
      | fromJust (elemIndex (maximum a) a) == 3 = Adv
      | otherwise                               = Verb


{- TESTING -}


-- wnReplaceTest1 :: String -> String
-- wnReplaceTest1 a = do
--     w <- asks wne
--     wnPos <- wnTypePOS a

wnSearchTest1 :: String -> Net b
wnSearchTest1 a = do
    h <- asks socket
    w <- asks wne
    result1 <- io $ return $ runs w (search a Noun AllSenses)
    result2 <- io $ return $ runs w (search a Verb AllSenses)
    result3 <- io $ return $ runs w (search a Adj AllSenses)
    result4 <- io $ return $ runs w (search a Adv AllSenses)
    io $ hPrintf h "PRIVMSG %s :Noun -> " chan; io $ hPrint h result1; io $ hPrintf h "\r\n"
    io $ hPrintf h "PRIVMSG %s :Verb -> " chan; io $ hPrint h result2; io $ hPrintf h "\r\n"
    io $ hPrintf h "PRIVMSG %s :Adj -> " chan; io $ hPrint h result3; io $ hPrintf h "\r\n"
    io $ hPrintf h "PRIVMSG %s :Adv -> " chan; io $ hPrint h result4; io $ hPrintf h "\r\n"

wnSearchTest2 :: String -> Net b
wnSearchTest2 a = do
    h <- asks socket
    w <- asks wne
    wnPos <- wnTypePOS a
    result <- io $ return $ runs w (search a wnPos 1)
    io $ hPrintf h "PRIVMSG %s :" chan; io $ hPrint h result; io $ hPrintf h "\r\n"

wnGetWordsTest1 a = do
    h <- asks socket
    w <- asks wne
    wnPos <- wnTypePOS a
    result <- io $ return $ map (getWords . getSynset) (runs w (search a wnPos AllSenses))
    io $ printf "PRIVMSG %s :" chan; io $ print result; io $ printf "\r\n"

wnGetWordsTest2 a = do
    h <- asks socket
    w <- asks wne
    wnPos <- wnTypePOS a
    result <- io $ return $ (nub $ concat $ map (getWords . getSynset) (runs w (search a wnPos AllSenses))) \\ (a : [])
    io $ printf "PRIVMSG %s :Words -> " chan; io $ print result; io $ printf "\r\n"
    io $ hPrintf h "PRIVMSG %s :Words -> " chan; io $ hPrint h result; io $ hPrintf h "\r\n"

wnGetWordsTest3 :: String -> Net String
wnGetWordsTest3 a = do
    w <- asks wne
    wnPos <- wnTypePOS a
    return $ replace '_' ' ' $ unwords $ (nub $ concat $ map (getWords . getSynset) (runs w (search a wnPos AllSenses))) \\ (a : [])

wnSearchHypernymTest1 :: String -> Net b
wnSearchHypernymTest1 a = do
    h <- asks socket
    w <- asks wne
    result1 <- io $ return $ runs w (relatedByList Hypernym (search a Noun AllSenses))
    result2 <- io $ return $ runs w (relatedByList Hypernym (search a Verb AllSenses))
    result3 <- io $ return $ runs w (relatedByList Hypernym (search a Adj AllSenses))
    result4 <- io $ return $ runs w (relatedByList Hypernym (search a Adv AllSenses))
    -- Spams IRC!
    -- io $ hPrintf h "PRIVMSG %s :Noun -> " chan; io $ hPrint h result1; io $ hPrintf h "\r\n"
    -- io $ hPrintf h "PRIVMSG %s :Verb -> " chan; io $ hPrint h result2; io $ hPrintf h "\r\n"
    -- io $ hPrintf h "PRIVMSG %s :Adj -> " chan; io $ hPrint h result3; io $ hPrintf h "\r\n"
    -- io $ hPrintf h "PRIVMSG %s :Adv -> " chan; io $ hPrint h result4; io $ hPrintf h "\r\n"
    io $ printf "PRIVMSG %s :Noun -> " chan; io $ print result1; io $ printf "\r\n"
    io $ printf "PRIVMSG %s :Verb -> " chan; io $ print result2; io $ printf "\r\n"
    io $ printf "PRIVMSG %s :Adj -> " chan; io $ print result3; io $ printf "\r\n"
    io $ printf "PRIVMSG %s :Adv -> " chan; io $ print result4; io $ printf "\r\n"

wnSearchHypernymTest2 :: String -> Net b
wnSearchHypernymTest2 a = do
    h <- asks socket
    w <- asks wne
    result1 <- io $ return $ runs w (closureOnList Hypernym (search a Noun AllSenses))
    result2 <- io $ return $ runs w (closureOnList Hypernym (search a Verb AllSenses))
    result3 <- io $ return $ runs w (closureOnList Hypernym (search a Adj AllSenses))
    result4 <- io $ return $ runs w (closureOnList Hypernym (search a Adv AllSenses))
    -- Spams IRC!
    -- io $ hPrintf h "PRIVMSG %s :Noun -> " chan; io $ hPrint h result1; io $ hPrintf h "\r\n"
    -- io $ hPrintf h "PRIVMSG %s :Verb -> " chan; io $ hPrint h result2; io $ hPrintf h "\r\n"
    -- io $ hPrintf h "PRIVMSG %s :Adj -> " chan; io $ hPrint h result3; io $ hPrintf h "\r\n"
    -- io $ hPrintf h "PRIVMSG %s :Adv -> " chan; io $ hPrint h result4; io $ hPrintf h "\r\n"
    io $ printf "PRIVMSG %s :Noun -> " chan; io $ print result1; io $ printf "\r\n"
    io $ printf "PRIVMSG %s :Verb -> " chan; io $ print result2; io $ printf "\r\n"
    io $ printf "PRIVMSG %s :Adj -> " chan; io $ print result3; io $ printf "\r\n"
    io $ printf "PRIVMSG %s :Adv -> " chan; io $ print result4; io $ printf "\r\n"

wnOverviewTest :: String -> Net b
wnOverviewTest a = do
    h <- asks socket
    w <- asks wne
    result <- io $ return $ runs w (getOverview a)
    io $ hPrintf h "PRIVMSG %s :" chan; io $ hPrint h result; io $ hPrintf h "\r\n"

wnWordTypeTest :: String -> Net b
wnWordTypeTest a = do
    h <- asks socket
    w <- asks wne
    result1 <- io $ (getIndexString w a Noun)
    result2 <- io $ (getIndexString w a Verb)
    result3 <- io $ (getIndexString w a Adj)
    result4 <- io $ (getIndexString w a Adv)
    io $ hPrintf h "PRIVMSG %s :Noun -> " chan; io $ hPrint h result1; io $ hPrintf h "\r\n"
    io $ hPrintf h "PRIVMSG %s :Verb -> " chan; io $ hPrint h result2; io $ hPrintf h "\r\n"
    io $ hPrintf h "PRIVMSG %s :Adj -> " chan; io $ hPrint h result3; io $ hPrintf h "\r\n"
    io $ hPrintf h "PRIVMSG %s :Adv -> " chan; io $ hPrint h result4; io $ hPrintf h "\r\n"
