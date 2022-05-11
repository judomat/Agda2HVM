module Main where

import Prelude hiding ( null , empty )

import Agda.Compiler.Backend
import Agda.Compiler.Common

import Agda.Main ( runAgda )

import Agda.Interaction.Options ( OptDescr(..) , ArgDescr(..) )

import Agda.Syntax.Treeless ( EvaluationStrategy(..) )

import Agda.TypeChecking.Pretty

import Agda.Utils.Either
import Agda.Utils.Functor
import Agda.Utils.Null
import Agda.Utils.Pretty ( prettyShow )

import Control.DeepSeq ( NFData )

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Data.Function
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import GHC.Generics ( Generic )

import ToHvm
import Syntax

import System.Process
import System.Environment (getArgs)
import System.Directory

import Utils
import Optimize

-- type HvmModule = [[HvmTerm]]
data HvmModule = HvmModule { isMain :: IsMain, defs :: [[HvmTerm]], name :: ModuleName }

backend' :: Backend' HvmOptions HvmOptions () HvmModule [HvmTerm]
backend' = Backend'
    {
        backendName             = "agda2HVM"
        , backendVersion        = Nothing
        , options               = Options
        , commandLineFlags      = []
        , isEnabled             = const True
        , preCompile            = hvmPreCompile
        , postCompile           = hvmPostCompile
        , preModule             = \ _ _ _ _ -> return $ Recompile ()
        , postModule            = hvmPostModule
        , compileDef            = hvmCompile
        , scopeCheckingSuffices = False
        , mayEraseType          = \ _ -> return True
    }

backend :: Backend
backend = Backend backend'

hvmPreCompile :: HvmOptions -> TCM HvmOptions
hvmPreCompile o = do
    liftIO $ createDirectoryIfMissing True "build"
    liftIO $ setCurrentDirectory "build"
    return o

hvmPostCompile :: HvmOptions -> IsMain -> Map ModuleName HvmModule -> TCM ()
hvmPostCompile opts main modulesDict = do
    let modules = Map.elems modulesDict
    let mainModuleName = case find (\m -> IsMain == isMain m) modules of
            Just m  -> prettyShow $ name m
            Nothing -> "out"

    let defss = map defs modules
    let defs = removeUnused $ concat defss

    let t = intercalate "\n\n" $ map (intercalate "\n" . map show) (filter (not . Data.List.null) (defs  ++ hvmPreamble))
    let fileName = mainModuleName
        fileNameHVM  = fileName ++ ".hvm"
        filenameC = fileName ++ ".c"
    liftIO $ T.writeFile ("./" ++ fileNameHVM) (T.pack t)
    liftIO $ callProcess "hvm" ["c", fileNameHVM]
    liftIO $ callProcess "clang" ["-Ofast", "-lpthread", "-o", fileName, filenameC]

hvmCompile :: HvmOptions -> () -> IsMain -> Definition -> TCM [HvmTerm]
hvmCompile opts _ isMain def = do
    ts <- toHvm def
            & (`evalStateT` initToHvmState)
            & (`runReaderT` initToHvmEnv opts)
    return $ map optimize ts

hvmPostModule :: HvmOptions -> () -> IsMain -> ModuleName -> [[HvmTerm]] -> TCM HvmModule
hvmPostModule options _ isMain modName sexprss = do

    return $ HvmModule { isMain = isMain, defs = sexprss, name = modName }

main :: IO ()
main = runAgda [backend]
