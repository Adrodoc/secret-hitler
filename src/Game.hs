module Game where

import           Control.Lens hiding (element)
import           Data.Maybe
import           Data.Monoid
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.List.NonEmpty as NonEmpty
import Data.Bool (bool)
import Control.Applicative ((<|>))

data Alignment =
  Good |
  Evil
  deriving stock (Show)

data Role =
  GoodRole |
  EvilRole |
  EvilLeaderRole
  deriving stock (Show)

data Vote =
  No |
  Yes
  deriving stock (Show)

data Player = Player {
  role  :: Role,
  vote  :: Maybe Vote,
  alive :: Bool
}
  deriving stock (Show, Generic)

data Policy =
  GoodPolicy |
  EvilPolicy
  deriving stock (Show)

data Government = Government {
  president :: PlayerId,
  chancellor :: PlayerId
}
  deriving stock (Show)

data NominateChancellorPhasePayload = NominateChancellorPhasePayload {
  governmentPrevious :: Maybe Government
}
  deriving stock (Show)

data VotePhasePayload = VotePhasePayload {
  governmentPrevious :: Maybe Government,
  chancellorCandidate :: PlayerId
}
  deriving stock (Show, Generic)

data PresidentDiscardPolicyPhasePayload = PresidentDiscardPolicyPhasePayload {
  chancellor :: PlayerId
}
  deriving stock (Show)

data GamePhase =
  NominateChancellorPhase NominateChancellorPhasePayload |
  VotePhase VotePhasePayload |
  PresidentDiscardPolicyPhase PresidentDiscardPolicyPhasePayload |
  ChancellorDiscardPolicyPhase
  deriving stock (Show)

data PresidentTracker = PresidentTracker {
    president :: PlayerId,
    regularPresidentLatest :: PlayerId
}
  deriving stock (Show, Generic)

newtype PlayerId =
  PlayerId Int
  deriving newtype (Show, Eq, Ord)

data Game = Game {
  phase                 :: GamePhase,
  -- players includes dead players too.
  -- Use the getter alivePlayers instead of #players wherever possible.
  players               :: Map PlayerId Player,
  drawPile              :: [Policy],
  goodPolicies          :: Int,
  evilPolicies          :: Int,
  presidentTracker :: PresidentTracker,
  electionTracker       :: Int
}
  deriving stock (Show, Generic)

data ClientEvent =
  UserInput PlayerId UserInput

data GameEvent =
  SucceedVote |
  FailVote

data UserInput =
  Vote Vote |
  NominateChancellor PlayerId

update :: Game -> ClientEvent -> (Game, Maybe GameEvent)
update game@(Game {phase}) (UserInput actor userInput)
  | VotePhase votePhasePayload <- phase, Vote vote <- userInput =
      registreVote game votePhasePayload actor vote
  | otherwise = error "invalid input" -- to-do. exception handlin

registreVote ::
  Game -> VotePhasePayload -> PlayerId -> Vote -> (Game, Maybe GameEvent)
registreVote game votePhasePayload actor vote =
  case resultOverall of
    Nothing -> (gameNew, Nothing)
    Just Yes -> (succeedVote gameNew, Just SucceedVote)
    Just No -> (failVote gameNew, Just FailVote)
  where
    resultOverall :: Maybe (Vote)
    resultOverall =
      fmap (bool No Yes) $
      fmap (> Sum 0) $
      fmap (foldMap voteToSum) $
      resultsIndividual
    resultsIndividual :: Maybe (Map PlayerId Vote)
    resultsIndividual = traverse (view #vote) (gameNew ^. alivePlayers)
    gameNew :: Game
    gameNew = set (#players . ix actor . #vote) (Just vote) game -- to-do. Are we fine with neither checking if the actor has voted already nor its existence here?
    voteToSum :: Vote -> Sum Integer
    voteToSum No = Sum (-1)
    voteToSum Yes = Sum 1
    succeedVote :: Game -> Game
    succeedVote =
      set
        #phase
        (
          PresidentDiscardPolicyPhase $
          PresidentDiscardPolicyPhasePayload $
          votePhasePayload ^. #chancellorCandidate
        )
      .
      set #electionTracker 0
    failVote :: Game -> Game
    failVote =
      set
        #phase
        (
          NominateChancellorPhase $
          NominateChancellorPhasePayload $
          votePhasePayload ^. #governmentPrevious
        )
      .
      over #presidentTracker updatePresidentTracker
      .
      over #electionTracker (+1)
    updatePresidentTracker :: PresidentTracker -> PresidentTracker
    updatePresidentTracker =
      fromMaybe (error "all players dying should not be possible")
      .
      passPresidencyRegularly (gameNew ^. alivePlayers)

alivePlayers :: Getter Game (Map PlayerId Player)
alivePlayers = #players . to (Map.filter (view #alive))

passPresidencyRegularly ::
  Map PlayerId value -> PresidentTracker -> Maybe PresidentTracker
passPresidencyRegularly playerIds presidentTracker =
  passPresidencyTo <$>
    (
      fst <$> (Map.lookupGT (presidentTracker ^. #regularPresidentLatest) playerIds)
      <|>
      (fmap NonEmpty.head $ NonEmpty.nonEmpty $ Map.keys $ playerIds)
    )
  where
    passPresidencyTo :: PlayerId -> PresidentTracker
    passPresidencyTo nextPresident =
      set #president nextPresident $
      set #regularPresidentLatest nextPresident $
      presidentTracker