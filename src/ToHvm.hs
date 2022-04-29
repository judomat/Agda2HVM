{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use lambda-case" #-}
{-# LANGUAGE FlexibleContexts #-}
module ToHvm where

import Prelude hiding ( null , empty )

import Agda.Compiler.Common
import Agda.Compiler.ToTreeless

import Agda.Syntax.Abstract.Name
import Agda.Syntax.Common
import Agda.Syntax.Internal ( conName, Clause, Telescope )
import Agda.Syntax.Literal
import Agda.Syntax.Treeless

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty

import Agda.Utils.Impossible
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Null
import Agda.Utils.Pretty
import Agda.Utils.Singleton

import Control.DeepSeq ( NFData )

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State

import Data.Char
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import GHC.Generics ( Generic )

import Syntax
import Utils (safeTail, safeInit)

data HvmOptions = Options deriving (Generic, NFData)

data ToHvmEnv = ToHvmEnv
  { toHvmOptions :: HvmOptions
  , toHvmVars    :: [HvmAtom]
  , currentDef   :: HvmAtom
  }

initToHvmEnv :: HvmOptions -> ToHvmEnv
initToHvmEnv opts = ToHvmEnv opts [] ""

addVarBinding :: HvmAtom -> ToHvmEnv -> ToHvmEnv
addVarBinding x env = env { toHvmVars = x : toHvmVars env }

data ToHvmState = ToHvmState
  { toHvmFresh     :: [HvmAtom]          -- Used for locally bound named variables
  , toHvmDefs      :: Map QName HvmAtom  -- Used for global definitions
  , toHvmUsedNames :: Set HvmAtom        -- Names that are already in use (both variables and definitions)
  }

-- This is an infinite supply of variable names
-- a, b, c, ..., z, a1, b1, ..., z1, a2, b2, ...
-- We never reuse variable names to make the code easier to
-- understand.
freshVars :: [HvmAtom]
freshVars = concat [ map (<> i) xs | i <- "": map show [1..] ]
  where
    xs = map (:"") ['a'..'z']

-- These are names that should not be used by the code we generate
reservedNames :: Set HvmAtom
reservedNames = Set.fromList
  [
  -- TODO: add more
  ]

initToHvmState :: ToHvmState
initToHvmState = ToHvmState
  { toHvmFresh     = freshVars
  , toHvmDefs      = Map.empty
  , toHvmUsedNames = reservedNames
  }

type ToHvmM a = StateT ToHvmState (ReaderT ToHvmEnv TCM) a

freshHvmAtom :: ToHvmM HvmAtom
freshHvmAtom = do
  names <- gets toHvmFresh
  case names of
    [] -> fail "No more variables!"
    (x:names') -> do
      modify $ \st -> st { toHvmFresh = names' }
      ifM (isNameUsed x) freshHvmAtom $ {-otherwise-} do
        setNameUsed x
        return x

getEvaluationStrategy :: ToHvmM EvaluationStrategy
getEvaluationStrategy = return LazyEvaluation

getBindinds :: ToHvmM [HvmAtom]
getBindinds = reader toHvmVars

getVarName :: Int -> ToHvmM HvmAtom
getVarName i = reader $ (\vars -> if i < length vars then vars !! i else error $ "cannot get index " ++ show i ++ " in " ++ show vars) . toHvmVars

getCurrentDef :: ToHvmM HvmAtom
getCurrentDef = reader currentDef

withCurrentDef :: HvmAtom -> ToHvmM a -> ToHvmM a
withCurrentDef a = local (\env -> env { currentDef = a })

withFreshVar :: (HvmAtom -> ToHvmM a) -> ToHvmM a
withFreshVar f = do
  x <- freshHvmAtom
  local (addVarBinding x) $ f x

withFreshVars :: Int -> ([HvmAtom] -> ToHvmM a) -> ToHvmM a
withFreshVars i f
  | i <= 0    = f []
  | otherwise = withFreshVar $ \x -> withFreshVars (i-1) (f . (x:))

saveDefName :: QName -> HvmAtom -> ToHvmM ()
saveDefName n a = modify $ \s -> s { toHvmDefs = Map.insert n a (toHvmDefs s) }

isNameUsed :: HvmAtom -> ToHvmM Bool
isNameUsed x = Set.member x <$> gets toHvmUsedNames

setNameUsed :: HvmAtom -> ToHvmM ()
setNameUsed x = modify $ \s ->
  s { toHvmUsedNames = Set.insert x (toHvmUsedNames s) }

-- Extended alphabetic characters that are allowed to appear in
-- a Hvm identifier
hvmExtendedAlphaChars :: Set Char
hvmExtendedAlphaChars = Set.fromList
  [ '!' , '$' , '%' , '&' , '*' , '+' , '-' , '.' , '/' , ':' , '<' , '=' , '>'
  , '?' , '@' , '^' , '_' , '~'
  ]

-- Categories of unicode characters that are allowed to appear in
-- a Hvm identifier
hvmAllowedUnicodeCats :: Set GeneralCategory
hvmAllowedUnicodeCats = Set.fromList
  [ UppercaseLetter , LowercaseLetter , TitlecaseLetter , ModifierLetter
  , OtherLetter , NonSpacingMark , SpacingCombiningMark , EnclosingMark
  , DecimalNumber , LetterNumber , OtherNumber , ConnectorPunctuation
  , DashPunctuation , OtherPunctuation , CurrencySymbol , MathSymbol
  , ModifierSymbol , OtherSymbol , PrivateUse
  ]

-- True if the character is allowed to be used in a Hvm identifier
isValidHvmChar :: Char -> Bool
isValidHvmChar x
  | isAscii x = isAlphaNum x || x `Set.member` hvmExtendedAlphaChars
  | otherwise = generalCategory x `Set.member` hvmAllowedUnicodeCats

-- Creates a valid Hvm name from a (qualified) Agda name.
-- Precondition: the given name is not already in toHvmDefs.
makeHvmName :: QName -> ToHvmM HvmAtom
makeHvmName n = do
  a <- go $ fixName $ prettyShow $ qnameName n
  saveDefName n a
  setNameUsed a
  return a
  where
    nextName = ('z':) -- TODO: do something smarter

    go s     = ifM (isNameUsed s) (go $ nextName s) (return s)

    fixName s = do
      let s'  = concatMap fixChar s
      let (x:xs) = if isNumber (head s') then "z" ++ s' else s'
      -- 'U':x:xs -- TODO: do something smarter
      toUpper x:xs

    fixChar c
      | isValidHvmChar c = [c]
      | otherwise           = "\\x" ++ toHex (ord c) ++ ";"

    toHex 0 = ""
    toHex i = toHex (i `div` 16) ++ [fourBitsToChar (i `mod` 16)]

fourBitsToChar :: Int -> Char
fourBitsToChar i = "0123456789ABCDEF" !! i
{-# INLINE fourBitsToChar #-}

class ToHvm a b where
    toHvm :: a -> ToHvmM b

instance ToHvm QName HvmAtom where
    toHvm n = do
        r <- Map.lookup n <$> gets toHvmDefs
        case r of
            Nothing -> makeHvmName n
            Just a  -> return a

paramsNumber :: Num a => TTerm -> a
paramsNumber (TLam v) = 1 + paramsNumber v
paramsNumber _ = 0

traverseLams :: TTerm -> TTerm
traverseLams (TLam v) = traverseLams v
traverseLams t = t

traverseCases :: TTerm -> TTerm
traverseCases (TCase i info v bs) = traverseCases v
traverseCases t = t

makeLamFromParams :: [HvmAtom] -> HvmTerm -> HvmTerm
makeLamFromParams xs body = foldr Lam body xs

curryRuleName :: String -> Int -> String
curryRuleName f i = f ++ "_" ++ show i

makeRule :: String -> Int -> ([HvmAtom] -> ToHvmM HvmTerm) -> ToHvmM [HvmTerm]
makeRule name nparams lbody = withFreshVars nparams $ \params -> do
  let name' = curryRuleName name nparams
  body' <- lbody params
  let dn = Rule (Ctr name' (map Var params)) body'
  case params of
    [] -> do
      return [dn]
    params -> do
      let d0 = curryRule [] name params
      return [d0, dn]

{-
  (Id_0) = @a @b @c (Id_3 a b c)
  (Id_1 a) = @b @c (Id_3 a b c)
  (Id_2 a b) =  @c (Id_3 a b c)
  (Id_3 a b c)= c
-}
curryRule :: [HvmAtom] -> HvmAtom -> [HvmAtom] -> HvmTerm
curryRule cparams f lparams = Rule (Ctr (curryRuleName f cparamsLen) $ map Var cparams) (makeLamFromParams lparams (App (Var $ curryRuleName f paramsLen) (map Var cparams ++ map Var lparams)))
  where
    cparamsLen = length cparams
    lparamsLen = length lparams
    paramsLen = cparamsLen + lparamsLen

instance ToHvm Definition [HvmTerm] where
    toHvm def
        | defNoCompilation def ||
          not (usableModality $ getModality def) = return []
    toHvm def = do
        let f = defName def
        f' <- toHvm f
        withCurrentDef f' $ do
          case theDef def of
              Axiom {}         -> return []
              GeneralizableVar -> return []
              d@Function{} | d ^. funInline -> return []
              Function {}      -> do
                  strat <- getEvaluationStrategy
                  maybeCompiled <- liftTCM $ toTreeless strat f
                  case maybeCompiled of
                      Just l@(TLam _) -> do
                          let nparams = paramsNumber l
                          let body = traverseLams l
                          makeRule f' nparams (\_ -> toHvm body)
                          -- case body of
                          --   -- TLet _ c@TCase{} -> do
                          --   --   let ctrss = getCtrs c
                          --   --   -- body <- toHvm c
                          --   --   return $ map (\ctrs -> Rule (Ctr (curryRuleName f' nparams) (map Var ctrs)) (Var "body")) ctrss
                          --   c@TCase{} -> do
                          --     let ctrss = getCtrs c
                          --     -- body <- toHvm c
                          --     return $ map (\ctrs -> Rule (Ctr (curryRuleName f' nparams) (map Var ctrs)) (Var "body")) ctrss
                          --   _ -> makeRule f' nparams (\_ -> toHvm body)
                      Just t -> do
                          body <- toHvm t
                          return [Rule (Ctr (curryRuleName f' 0) []) body]
                      Nothing   -> error $ "Could not compile Function " ++ f' ++ ": treeless transformation returned Nothing"
              Primitive {}     -> return []
              PrimitiveSort {} -> return []
              Datatype {}      -> return []
              Record {}        -> undefined
              Constructor { conSrcCon=chead, conArity=nparams } -> do
                let c = conName chead
                c' <- toHvm c
                makeRule c' nparams (return . Ctr c' . map Var)

              AbstractDefn {}  -> __IMPOSSIBLE__
              DataOrRecSig {}  -> __IMPOSSIBLE__

orElse :: Maybe a -> a -> a
orElse (Just x) _ = x
orElse _ y = y

argRanges' :: (Enum a, Num a) => [a] -> a -> [[a]]
argRanges' []     _ = []
argRanges' (x:xs) last = let nss = argRanges' xs (last+x) in [last..(last+x-1)]:nss

getAtIndices xs [] = []
getAtIndices xs (i:is) = xs!!i:(getAtIndices xs is)

instance ToHvm TTerm HvmTerm where
    toHvm v = case v of
        TVar i  -> do
            name <- getVarName i
            start <- getEvaluationStrategy
            return $ Parenthesis $ Var name
        TPrim p -> undefined
        TDef d  -> do
            d' <- toHvm d
            -- Always evaluate Def first with 0 arguments (see Notes Thu 28 Apr)
            return $ App (Var $ curryRuleName d' 0) []
        TApp f args -> do
            f'    <- toHvm f
            args' <- traverse toHvm args
            case f' of
              Var ruleName -> return $ App (Var $ curryRuleName ruleName $ length args') args'
              _ -> return $ App f' args'
        TLam v  -> withFreshVar $ \x -> do
            body <- toHvm v
            return $ Lam x body
        TCon c -> do
            c' <- toHvm c
            return $ App (Var $ curryRuleName c' 0) []
        TLet u v -> do
          expr <- toHvm u
          withFreshVar $ \x -> do
            body <- toHvm v
            return $ Let x expr body
        c@(TCase i info v bs) -> do
          let ctrss = getCtrs c
          defName <- getCurrentDef
          let splitRuleName = defName ++ "_split"
          bindings <- getBindinds
          let body = App (Var splitRuleName) (map Var bindings)

          rules <- traverse (\ctrs -> do
            let nargs = map (\((_, nargs), _) -> nargs) ctrs
            let totalArgs = sum nargs
            let argRanges = argRanges' nargs 0

            withFreshVars totalArgs $ \args -> do
              constructors <- traverse (\(((name, nargs), _), argIndices) -> do
                  let cargs = getAtIndices args argIndices
                  return $ Ctr name (map Var args)
                ) (zip ctrs argRanges)

              let infctrs = map Just constructors ++ repeat Nothing
              let all = zipWith orElse infctrs (map Var bindings)
              body <- toHvm $ (snd . last) ctrs
              let bigLet = foldr1 (.) (zipWith Let bindings constructors)
              return $ Rule (Ctr splitRuleName all) (bigLet body)
              ) ctrss

          if isUnreachable v then
              return $ Cases body rules
          else (do
            fallback <- toHvm v
            let fallbackRule = Rule (Ctr splitRuleName (map Var bindings)) fallback
            return $ Cases body (rules ++ [fallbackRule])
            )



        TUnit -> undefined
        TSort -> undefined
        TErased    -> return $ Var ""
        TCoerce u  -> undefined
        TError err -> return $ Var "error\n"
        TLit l     -> undefined

toHvmAltDef :: TTerm -> ToHvmM HvmTerm
toHvmAltDef v = case v of
  TDef d -> do
    d' <- toHvm d
    return $ Var d'
  t -> toHvm t

getCtr :: TAlt -> ((HvmAtom, Int), TTerm)
getCtr alt = case alt of
  TACon c nargs v -> ((prettyShow $ qnameName c, nargs), v)
  TAGuard{} -> __IMPOSSIBLE__ -- TODO
  TALit{} -> __IMPOSSIBLE__ -- TODO

getCtrs :: TTerm -> [[((HvmAtom, Int), TTerm)]]
getCtrs t = case t of
  TCase i info v bs -> do
    let calts = map getCtr bs
    concatMap (\t@(_, n) -> do
      let nss = getCtrs n
      map (t :) nss
      ) calts
  _ -> [[]]

{-
  (And a b) = (And_split_1 a b)
      (And_split_1 True b) = (And_split_2 True b)
      (And_split_1 a b) = False
      (And_split_2 a True) = True
      (And_split_2 a b) = False
-}
-- instance ToHvm TAlt (HvmTerm, HvmTerm) where
--   toHvm alt = case alt of
--     TACon c nargs v -> withFreshVars nargs $ \xs -> do
--       body <- toHvm v
--       let name = prettyShow $ qnameName c
--       return (Ctr name (map Var xs), body)
--     -- ^ Matches on the given constructor. If the match succeeds,
--     -- the pattern variables are prepended to the current environment
--     -- (pushes all existing variables aArity steps further away)
--     TAGuard{} -> __IMPOSSIBLE__ -- TODO
--     TALit{} -> __IMPOSSIBLE__ -- TODO