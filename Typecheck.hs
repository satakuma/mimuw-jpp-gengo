{-# LANGUAGE FlexibleInstances #-}

module Typecheck
  -- ( runTypecheck
  -- , TPException(..)
  -- , typecheck
  -- , TypecheckM
  -- ) where
  where

import           AbsGengo
import           Control.Monad.Except
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Identity
import           Control.Monad.State.Lazy
import           Data.Map
import qualified Data.Map                 as Map
import           Data.Maybe               (maybeToList)
import           Data.Void                (Void)
import           ErrM
import           Utils


type Env = Map Ident TPType

env0 :: Env
env0 = Map.empty

type TypecheckM a = ReaderT Env (ExceptT TPException IO) a

runTypecheck :: TypecheckM a -> IO (Either TPException a)
runTypecheck tp = runExceptT (runReaderT tp env0)

data TPException
  = TypecheckError String
  | MismatchedType TPType TPType Pos
  | NoVariable String Pos
  | ForWithoutGenerator TPType Pos
  deriving (Eq, Ord, Show, Read)

data TPType
  = TPFn [Arg] TPType
  | TPGn [Arg] TPType
  | TPGenerator TPType
  | TPInt
  | TPBool
  | TPString
  | TPVoid
  deriving (Eq, Ord, Show, Read)

class ToTypecheck a where
  typecheck :: a -> TypecheckM TPType

type Pos = BNFC'Position

instance ToTypecheck (Type' a) where
  typecheck (Int _) = return TPInt
  typecheck (Str _) = return TPString
  typecheck (Bool _) = return TPBool
  typecheck (Generator _ t) = do
    genType <- typecheck t
    return (TPGenerator genType)

instance ToTypecheck Arg where
  typecheck (VArg _ t _) = typecheck t
  typecheck (RefArg _ t _) = typecheck t

checkType :: Pos -> TPType -> TPType -> TypecheckM ()
checkType p expected returned =
  if expected /= returned then throwError (MismatchedType expected returned p) else return ()

lookupVar :: Ident -> TypecheckM (Maybe TPType)
lookupVar ident = do
  env <- ask
  return $ Map.lookup ident env

instance ToTypecheck (Expr' Pos) where
  typecheck (EVar p ident@(Ident name)) = do
    t <- lookupVar ident
    case t of
      Just t' -> return t'
      _ -> ask >>= (liftIO . putStrLn . show) >> throwError (NoVariable name p)
  typecheck (ELitInt _ _) = return TPInt
  typecheck (ELitTrue _) = return TPBool
  typecheck (ELitFalse _) = return TPBool
  typecheck (EString _ _) = return TPString
  typecheck (Neg p e) = do
    t <- typecheck e
    checkType p TPInt t
    return TPInt
  typecheck (Not p e) = do
    t <- typecheck e
    checkType p TPBool t
    return TPBool
  typecheck (EMul p e1 _ e2) = do
    t1 <- typecheck e1
    checkType p TPInt t1
    t2 <- typecheck e2
    checkType p TPInt t2
    return TPInt
  typecheck (EAdd p e1 _ e2) = do
    t1 <- typecheck e1
    checkType p TPInt t1
    t2 <- typecheck e2
    checkType p TPInt t2
    return TPInt
  typecheck (ERel p e1 _ e2) = do
    t1 <- typecheck e1
    checkType p TPInt t1
    t2 <- typecheck e2
    checkType p TPInt t2
    return TPBool
  typecheck (EAnd p e1 e2) = do
    t1 <- typecheck e1
    checkType p TPBool t1
    t2 <- typecheck e2
    checkType p TPBool t2
    return TPBool
  typecheck (EOr p e1 e2) = do
    t1 <- typecheck e1
    checkType p TPBool t1
    t2 <- typecheck e2
    checkType p TPBool t2
    return TPBool
  typecheck (EApp p ident@(Ident name) args) = do
    t <- lookupVar ident
    case t of
      Just (TPFn args' rett) -> do
        sequence_ $ zipWith (checkArg p) args' args
        return rett
      Just (TPGn argst' rett) -> do
        undefined
        -- sequence_ $ zipWith (checkType p) argst' argst
        -- return (TPGenerator rett)
      Nothing -> do
        argst <- mapM typecheck args
        if name `elem` builtInNames then
          typecheckBuiltIn p name argst
        else throwError (NoVariable name p)
      _ -> throwError (NoVariable name p)
    where
      checkArg :: Pos -> Arg -> Expr -> TypecheckM ()
      checkArg pos arg expr =
        case arg of
          VArg _ t ident -> do
            t' <- typecheck t
            expr' <- typecheck expr
            checkType pos t' expr'
          RefArg _ t ident -> do
            t' <- typecheck t
            expr' <- typecheck expr
            checkType pos t' expr'
            case expr of
              EVar _ _ -> return ()
              _ -> throwError $ TypecheckError "non-variable expression passed as a reference"


typecheckBuiltIn :: Pos -> String -> [TPType] -> TypecheckM TPType
typecheckBuiltIn p name args = do
  case name of
    "print" -> do
      when (length args /= 1) $ throwError (TypecheckError "Invalid argument count for the print function")
      when (not ((head args) `elem` [TPInt, TPString, TPBool])) $ throwError (TypecheckError "Invalid argument type for print function")
      return TPVoid
    "next" -> do
      when (length args /= 1) $ throwError (TypecheckError "Invalid argument count for the next function")
      case head args of
        TPGenerator gtype -> return gtype
        _ -> throwError (TypecheckError "Invalid argument type for the next function")


instance ToTypecheck [Stmt] where
  typecheck [] = return TPVoid
  typecheck (stmt:stmts) =
    case stmt of
      Empty _ -> rest
      BStmt _ block -> typecheck block >> rest
      Init p t ident e -> do
        t' <- typecheck t
        e' <- typecheck e
        checkType p t' e'
        local (Map.insert ident t') rest
      Ass p ident e -> do
        e' <- typecheck e
        t <- lookupVar ident
        case t of
          Just t' -> checkType p t' e' >> rest
          _ -> let (Ident name) = ident in throwError (NoVariable name p)
      Ret p e -> typecheck e >> rest
      Yield p e -> typecheck e >> rest
      SExp p e -> typecheck e >> rest
      NestFn p tdef -> do
        t <- typecheck tdef
        local (Map.insert (getTopDefIdent tdef) t) rest
      Break _ -> rest
      Continue _ -> rest
      Cond p block -> typecheck block >> rest
      While p e block -> do
        e' <- typecheck e
        checkType p TPBool e'
        typecheck block
        rest
      For p ident e block -> do
        e' <- typecheck e
        case e' of 
          TPGenerator gent -> do
            local (Map.insert ident gent) (typecheck block)
            rest
          t -> throwError (ForWithoutGenerator t (hasPosition e))
    where
      rest = typecheck stmts
    
instance ToTypecheck If where
  typecheck ifStmt = case ifStmt of
    If p e b -> do
      e' <- typecheck e
      checkType p TPBool e'
      typecheck b
    IfElse p e b elseBlock -> do
      e' <- typecheck e
      checkType p TPBool e'
      typecheck b
      typecheck elseBlock

instance ToTypecheck Else where
  typecheck elseStmt = case elseStmt of
    ElseBlock p b -> typecheck b
    ElseIf p ifStmt -> typecheck ifStmt

typecheckYieldReturn :: TPType -> [Stmt] -> TypecheckM ()
typecheckYieldReturn _ [] = return ();
typecheckYieldReturn expected (stmt:stmts) =
  case stmt of
      BStmt _ (Block _ block) -> typecheckYieldReturn expected block >> rest
      Init p t ident e -> do
        t' <- typecheck t
        local (Map.insert ident t') rest
      Ret p e -> do
        t <- typecheck e
        when (t /= expected) $ throwError (TypecheckError "invalid return")
        rest
      Yield p e -> do
        t <- typecheck e
        when (t /= expected) $ throwError (TypecheckError "invalid yield")
        rest
      NestFn p tdef -> do
        t <- typecheck tdef
        local (Map.insert (getTopDefIdent tdef) t) rest
      Cond p block -> typecheckYieldReturnIf block >> rest
      While p _ (Block _ block) -> typecheckYieldReturn expected block >> rest
      For p ident e (Block _ block) -> do
        e' <- typecheck e
        case e' of 
          TPGenerator gent -> do
            local (Map.insert ident gent) (typecheckYieldReturn expected block)
            rest
          _ -> rest
      _ -> rest
  where
    rest = typecheckYieldReturn expected stmts
    typecheckYieldReturnIf ifStmt = case ifStmt of
      If _ _ (Block _ stmts) -> typecheckYieldReturn expected stmts
      IfElse _ _ (Block _ stmts) elseStmt -> do
        typecheckYieldReturn expected stmts
        typecheckYieldReturnElse elseStmt
    typecheckYieldReturnElse elseStmt = case elseStmt of
      ElseBlock _ (Block _ stmts) -> typecheckYieldReturn expected stmts
      ElseIf _ ifStmt -> typecheckYieldReturnIf ifStmt

{-
extractYieldsReturns :: [Stmt] -> [Stmt]
extractYieldsReturns = Prelude.foldr ((++) . extractStmt) [] 
  where
    extractStmt stmt = case stmt of
      BStmt _ (Block _ stmts) -> extractYieldsReturns stmts
      Cond _ block -> extractIf block
      r@(Ret _ _) -> [r]
      y@(Yield _ _) -> [y]
      While _ _ (Block _ stmts) -> extractYieldsReturns stmts
      For _ _ _ (Block _ stmts) -> extractYieldsReturns stmts 
      _ -> []
    extractIf ifStmt = case ifStmt of
      If _ _ (Block _ stmts) -> extractYieldsReturns stmts
      IfElse _ _ (Block _ stmts) elseStmt -> extractYieldsReturns stmts ++ extractElse elseStmt
    extractElse elseStmt = case elseStmt of
      ElseBlock _ (Block _ stmts) -> extractYieldsReturns stmts
      ElseIf _ ifStmt -> extractIf ifStmt

checkReturnType :: TPType -> Block -> TypecheckM ()
checkReturnType expected (Block _ stmts) = mapM_ checkStmtReturnType yieldsReturns
  where
    checkStmtReturnType :: Stmt -> TypecheckM()
    checkStmtReturnType stmt =
      case stmt of
        Ret p e -> do
          e' <- typecheck e
          when (e' /= expected) $ throwError (TypecheckError "invalid return")
        Yield p _ -> throwError (TypecheckError "invalid yield in a function")
        _ -> return ()
    yieldsReturns = extractYieldsReturns stmts

checkYieldType :: TPType -> Block -> TypecheckM ()
checkYieldType expected (Block _ stmts) = mapM_ checkStmtYieldType yieldsReturns
  where
    checkStmtYieldType :: Stmt -> TypecheckM()
    checkStmtYieldType stmt =
      case stmt of
        Yield p e -> do
          e' <- typecheck e
          when (e' /= expected) $ throwError (TypecheckError "invalid yield")
        Ret p _ -> throwError (TypecheckError "invalid return in a generator")
        _ -> return ()
    yieldsReturns = extractYieldsReturns stmts
-}

instance ToTypecheck Block where
  typecheck (Block p stmts) = typecheck stmts

instance ToTypecheck TopDef where
  typecheck (FnDef p ident args rtype block@(Block _ stmts)) = do
    tpArgs <- mapM typecheck args
    tpRtype <- typecheck rtype
    let fnType = TPFn args tpRtype 
    let newVars = (ident, fnType) : (zip (Prelude.map getArgIdent args) tpArgs)
    let updateEnv env = Prelude.foldl (\e (k, v) -> Map.insert k v e) env newVars
    local updateEnv (typecheck block)
    local updateEnv (typecheckYieldReturn tpRtype stmts)
    return fnType
  typecheck (GnDef p ident args rtype block@(Block _ stmts)) = undefined
  {-do
    tpArgs <- mapM typecheck args
    tpRtype <- typecheck rtype
    let gnType = TPGn tpArgs tpRtype 
        newVars = (ident, gnType) : (zip (Prelude.map getArgIdent args) tpArgs)
        updateEnv env = Prelude.foldl (\e (k, v) -> Map.insert k v e) env newVars
     in do
       local updateEnv (typecheck block)
       -- local updateEnv (checkReturnType tpRtype block)
       local updateEnv (typecheckYieldReturn tpRtype stmts)
       return gnType
      -}


instance ToTypecheck Program where
  typecheck (Program p []) = do
    mainFn <- lookupVar mainFnIdent
    case mainFn of
      Just (TPFn [] TPInt) -> return TPInt
      _ -> throwError (TypecheckError "invalid main type or no main")
  typecheck (Program p (tdef:tdefs)) = do
    t <- typecheck tdef
    local (Map.insert (getTopDefIdent tdef) t) (typecheck $ Program p tdefs)
