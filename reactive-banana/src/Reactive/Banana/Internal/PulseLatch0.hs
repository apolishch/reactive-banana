{-----------------------------------------------------------------------------
    reactive-banana
------------------------------------------------------------------------------}
{-# LANGUAGE Rank2Types, RecursiveDo, ExistentialQuantification,
    TypeSynonymInstances #-}
module Reactive.Banana.Internal.PulseLatch0 where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans.RWS
import Control.Monad.IO.Class

import Data.Monoid (Endo(..))

import Reactive.Banana.Internal.Cached

import Data.Hashable
import Data.Unique.Really
import qualified Data.Vault as Vault
import qualified Data.HashMap.Lazy as Map

type Map = Map.HashMap

{-----------------------------------------------------------------------------
    Graph data type
------------------------------------------------------------------------------}
data Graph = Graph
    { grPulse  :: Values                    -- pulse values
    , grLatch  :: Values                    -- latch values
    
    , grCache  :: Values                    -- cache for initialization
    , grDeps   :: Map SomeNode [SomeNode]   -- dependency information
    }

instance HasVault Network where
    retrieve key = Vault.lookup key . grCache <$> get
    write key a  = modify $ \g -> g { grCache = Vault.insert key a (grCache g) }

type Values = Vault.Vault
type Key    = Vault.Key

emptyGraph :: Graph
emptyGraph = Graph
    { grPulse  = Vault.empty
    , grLatch  = Vault.empty
    , grCache  = Vault.empty
    , grDeps   = Map.empty
    }

{-----------------------------------------------------------------------------
    Graph evaluation
------------------------------------------------------------------------------}
step :: Pulse a -> Graph -> IO (Maybe a, Graph)
step = undefined
    -- * Figure out which nodes need to be evaluated.
    -- All nodes that are connected to current input nodes must be evaluated.
    -- The other nodes don't have to be evaluated, because they yield
    -- Nothing / don't change anyway.
    --
    -- * Build an evaluation order
    -- * Perform evaluations
    -- * read output value

{-----------------------------------------------------------------------------
    Network monad
------------------------------------------------------------------------------}
-- reader / writer / state monad
type Network = RWST Graph (Endo Graph) Graph IO

-- change a graph "atomically"
runNetworkAtomic :: Network a -> Graph -> IO (a, Graph)
runNetworkAtomic m g1 = mdo
    (x, g2, w2) <- runRWST m g3 g1  -- apply early graph gransformations
    let g3 = appEndo w2 g2          -- apply late  graph transformations
    return (x, g3)
    
-- write pulse value immediately
writePulse :: Key (Maybe a) -> Maybe a -> Network ()
writePulse key x =
    modify $ \g -> g { grPulse = Vault.insert key x $ grPulse g }

-- read pulse value immediately
readPulse :: Key (Maybe a) -> Network (Maybe a)
readPulse key = (join . Vault.lookup key . grPulse) <$> get

-- write latch value immediately
writeLatch :: Key a -> a -> Network ()
writeLatch key x =
    modify $ \g -> g { grLatch = Vault.insert key x $ grLatch g }

-- read latch value immediately
readLatch :: Key a -> Network a
readLatch key = (maybe err id . Vault.lookup key . grLatch) <$> get
    where err = error "readLatch: latch not initialized!"

-- write latch value for future
writeLatchFuture :: Key a -> a -> Network ()
writeLatchFuture key x =
    tell $ Endo $ \g -> g { grLatch = Vault.insert key x $ grLatch g }

-- read future latch value
-- Note [LatchFuture]:
--   warning: forcing the value early will likely result in an infinite loop
readLatchFuture :: Key a -> Network a
readLatchFuture key = (maybe err id . Vault.lookup key . grLatch) <$> ask
    where err = error "readLatchFuture: latch not found!"

-- add a dependency
dependOn :: SomeNode -> SomeNode -> Network ()
dependOn x (P y) = -- dependency on a pulse is added directly
    modify $ \g -> g { grDeps = Map.insertWith (++) x [P y] $ grDeps g }
dependOn x (L y) = -- dependcy on a latch breaks the vicious cycle
    undefined

dependOns :: SomeNode -> [SomeNode] -> Network ()
dependOns x = mapM_ $ dependOn x

{-----------------------------------------------------------------------------
    Pulse and Latch types
------------------------------------------------------------------------------}
{-
    evaluateL/P
        calculates the next value and makes sure that it's cached
    valueL/P
        retrieves the current value
    futureL
        future value of the latch
        see note [LatchFuture]
    uidL/P
        used for dependency tracking and evaluation order
-}

data Pulse a = Pulse
    { evaluateP :: Network ()
    , valueP    :: Network (Maybe a)
    , uidP      :: Unique
    }

data Latch a = Latch
    { evaluateL :: Network ()
    , valueL    :: Network a
    , futureL   :: Network a
    , uidL      :: Unique
    }

{- Note [LatchCreation]

When creating a new latch from a pulse, we assume that the
pulse cannot fire at the moment that the latch is created.
This is important when switching latches, because of note [PulseCreation].

Likewise, when creating a latch, we assume that we do not
have to calculate the previous latch value.

Note [PulseCreation]

We assume that we do not have to calculate a pulse occurrence
at the moment we create the pulse. Otherwise, we would have
to recalculate the dependencies *while* doing evaluation;
this is a recipe for desaster.

-}

-- make pulse from evaluation function
pulse :: Network (Maybe a) -> Network (Pulse a)
pulse eval = do
    key <- liftIO Vault.newKey
    uid <- liftIO newUnique
    return $ Pulse
        { evaluateP = writePulse key =<< eval
        , valueP    = readPulse key
        , uidP      = uid
        }

neverP :: Network (Pulse a)
neverP = do
    uid <- liftIO newUnique
    return $ Pulse
        { evaluateP = return ()
        , valueP    = return Nothing
        , uidP      = uid
        }

-- make latch from initial value and evaluation function
latch :: a -> Network (Maybe a) -> Network (Latch a)
latch a eval = do
    key <- liftIO Vault.newKey
    uid <- liftIO newUnique

    -- Initialize with future latch value.
    -- See note [LatchCreation].
    writeLatchFuture key a

    return $ Latch
        { evaluateL = maybe (return ()) (writeLatchFuture key) =<< eval
        , valueL    = readLatch key
        , futureL   = readLatchFuture key
        , uidL      = uid
        }

pureL :: a -> Network (Latch a)
pureL a = do
    uid <- liftIO newUnique
    return $ Latch
        { evaluateL = return ()
        , valueL    = return a
        , futureL   = return a
        , uidL      = uid
        }

{-----------------------------------------------------------------------------
    Existential quantification over Pulse and Latch
    for dependency tracking
------------------------------------------------------------------------------}
data SomeNode = forall a. P (Pulse a) | forall a. L (Latch a)

instance Eq SomeNode where
    (L x) == (L y)  =  uidL x == uidL y
    (P x) == (P y)  =  uidP x == uidP y
    _     == _      =  False

instance Hashable SomeNode where
    hashWithSalt s (P p) = hashWithSalt s $ uidP p
    hashWithSalt s (L l) = hashWithSalt s $ uidL l

{-----------------------------------------------------------------------------
    Combinators - basic
------------------------------------------------------------------------------}
stepperL :: a -> Pulse a -> Network (Latch a)
stepperL a p = do
    -- @a@ is indeed the future latch value. See note [LatchCreation].
    x <- latch a (valueP p)
    L x `dependOn` P p
    return x

accumP :: a -> Pulse (a -> a) -> Network (Pulse a)
accumP a p = mdo
        x       <- stepperL a result
        result  <- pulse $ eval <$> valueL x <*> valueP p
        -- Evaluation order of the result pulse does *not*
        -- depend on the latch. It does depend on latch value,
        -- though, so don't garbage collect that one.
        P result `dependOn` P p
        return result
    where
    eval a Nothing  = Nothing
    eval a (Just f) = let b = f a in b `seq` Just b  -- strict evaluation

applyP :: Latch (a -> b) -> Pulse a -> Network (Pulse b)
applyP f x = do
    result <- pulse $ fmap <$> valueL f <*> valueP x
    P result `dependOn` P x
    return result


mapP :: (a -> b) -> Pulse a -> Network (Pulse b)
mapP f p = do
    result <- pulse $ fmap f <$> valueP p
    P result `dependOn` P p
    return result

filterJustP :: Pulse (Maybe a) -> Network (Pulse a)
filterJustP p = do
    result <- pulse $ join <$> valueP p
    P result `dependOn` P p
    return result

unionWith :: (a -> a -> a) -> Pulse a -> Pulse a -> Network (Pulse a)
unionWith f px py = do
        result <- pulse $ eval <$> valueP px <*> valueP py
        P result `dependOns` [P px, P py]
        return result
    where
    eval (Just x) (Just y) = Just (f x y)
    eval (Just x) Nothing  = Just x
    eval Nothing  (Just y) = Just y
    eval Nothing  Nothing  = Nothing


applyL :: Latch (a -> b) -> Latch a -> Network (Latch b)
applyL lf lx = do
    -- The value in the next cycle is always the future value.
    -- See note [LatchCreation].
    let eval = ($) <$> futureL lf <*> futureL lx
    a <- eval
    result <- latch a $ fmap Just eval
    L result `dependOns` [L lf, L lx]
    return result

{-----------------------------------------------------------------------------
    Combinators - dynamic event switching
------------------------------------------------------------------------------}
observeP :: Pulse (Network a) -> Network (Pulse a)
observeP pn = do
    result <- pulse $ do
        mp <- valueP pn
        case mp of
            Just p  -> Just <$> p
            Nothing -> return Nothing
    P result `dependOn` P pn
    return result

switchP :: Pulse (Pulse a) -> Network (Pulse a)
switchP pp = mdo
    never <- neverP
    lp    <- stepperL never pp
    let
        eval = do
            newPulse <- valueP pp
            case newPulse of
                Nothing -> return ()
                Just p  -> P result `dependOn` P p  -- check in new pulse
            valueP =<< valueL lp                    -- fetch value from old pulse
            -- we have to use the *old* event value due to note [LatchCreation]
    result <- pulse eval
    P result `dependOns` [L lp, P pp]
    return result


switchL :: Latch a -> Pulse (Latch a) -> Network (Latch a)
switchL l p = mdo
    ll <- stepperL l p
    let
        -- switch to a new latch
        switchTo l = do
            L result `dependOn` L l
            futureL l
        -- calculate future value of the result latch
        eval = do
            mp <- valueP p
            case mp of
                Nothing -> futureL =<< valueL ll
                Just l  -> switchTo l

    a      <- futureL l                 -- see note [LatchCreation]
    result <- latch a $ Just <$> eval
    L result `dependOns` [L l, P p]
    return result


