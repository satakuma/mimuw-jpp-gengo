{-# LANGUAGE FlexibleInstances #-}

module Typecheck where

import           AbsGengo
import           Control.Monad.Except
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Identity
import           Control.Monad.State.Lazy
import qualified Data.Int
import           Data.Map
import           Data.List                (intercalate)
import qualified Data.Map                 as Map
import           Data.Maybe               (maybeToList)
import           Data.Void                (Void)
import           ErrM
import           Utils


-- Reader environment

data Env = Env {
  vars :: Map Ident TPType,
  hasReturn :: Bool,
  expRetType :: TPType
}

env0 :: Env
env0 = Env {
  vars = Map.empty,
  hasReturn = False,
  expRetType = TPVoid
}


-- Typechecker monad

type TypecheckM a = ReaderT Env (ExceptT TPException Identity) a

runTypecheck :: TypecheckM a -> Either TPException a
runTypecheck tp = runIdentity $ runExceptT (runReaderT tp env0)


-- Typechecker exceptions

data TPException
  = TypecheckError String Pos
  | MismatchedType TPType TPType Pos
  | NoVariable String Pos
  | NoReturn Pos
  | InvalidRefArg Pos
  | InvalidArgCount Data.Int.Int Data.Int.Int Pos
  deriving (Eq, Read)

instance Show TPException where
  show e =
    case e of
      TypecheckError s p -> "Typecheck error: " ++ s ++ showpos p
      MismatchedType t1 t2 p -> "Mismatched types: " ++ show t1 ++ " vs " ++ show t2 ++ showpos p
      NoVariable s p -> "No variable in scope: " ++ s ++ showpos p
      NoReturn p -> "A block does not have return statement" ++ showpos p
      InvalidRefArg p -> "Invalid expression for a reference argument" ++ showpos p
      InvalidArgCount c1 c2 p -> "Invalid function argument count: " ++ show c1 ++ " vs " ++ show c2 ++ showpos p
    where
      showpos pos = case pos of
        Just p -> " @ " ++ show p
        Nothing -> ""


-- Types for function arguments

data ArgKind
  = AKRef
  | AKVal
  deriving (Eq, Read)

data TPArgType = TPArgType ArgKind TPType
  deriving (Eq, Read)

instance Show ArgKind where
  show ak =
    case ak of
      AKRef -> "&"
      AKVal -> ""

instance Show TPArgType where
  show (TPArgType ak t) = show t ++ show ak

fromArgType :: ArgType -> TypecheckM TPArgType
fromArgType (VArg _ t) = typecheck t >>= return . TPArgType AKVal
fromArgType (RefArg _ t) = typecheck t >>= return . TPArgType AKRef

-- All types used in typechecking

data TPType
  = TPFn [TPArgType] TPType
  | TPInt
  | TPBool
  | TPString
  | TPVoid
  deriving (Eq, Read)

instance Show TPType where
  show t =
    case t of
      TPFn args rtype -> show rtype ++ "(" ++ intercalate "," (Prelude.map show args) ++ ")"
      TPInt -> "int"
      TPBool -> "bool"
      TPString -> "string"
      TPVoid -> "void"


-- Class implemented for almost all parser tokens.
-- `typecheck` typechecks argument contents and returns its type.

class ToTypecheck a where
  typecheck :: a -> TypecheckM TPType


instance ToTypecheck Type where
  typecheck (Int _) = return TPInt
  typecheck (Str _) = return TPString
  typecheck (Bool _) = return TPBool
  typecheck (Fun _ ret args) = do
    retType <- typecheck ret
    argsType <- mapM fromArgType args
    return (TPFn argsType retType)

instance ToTypecheck ArgType where
  typecheck (VArg _ t) = typecheck t
  typecheck (RefArg _ t) = typecheck t

instance ToTypecheck Arg where
  typecheck (Arg _ at _) = typecheck at


checkType :: Pos -> TPType -> TPType -> TypecheckM ()
checkType p expected returned =
  if expected /= returned then throwError (MismatchedType expected returned p) else return ()

lookupVar :: Ident -> TypecheckM (Maybe TPType)
lookupVar ident = asks (Map.lookup ident . vars)

insertVar :: Ident -> TPType -> Env -> Env
insertVar ident t env = env { vars = Map.insert ident t (vars env) }

insertHasReturn :: Env -> Env
insertHasReturn env = env { hasReturn = True }


instance ToTypecheck (Expr' Pos) where
  typecheck (EVar p ident@(Ident name)) = do
    t <- lookupVar ident
    case t of
      Just t' -> return t'
      _ -> throwError (NoVariable name p)
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
  typecheck (ELambda p args rtype block) = do
    argTypes <- mapM (fromArgType . argToArgType) args
    args' <- mapM typecheck args
    rtype' <- typecheck rtype
    let fnType = TPFn argTypes rtype'
    let newVars = zip (Prelude.map getArgIdent args) args'
    let updateEnv env = Prelude.foldl (\e (k, v) -> insertVar k v e) env newVars
    local updateEnv (typecheckFnBlock rtype' block)
    return fnType
  typecheck (EApp p ident@(Ident name) args) = do
    t <- lookupVar ident
    case t of
      Just (TPFn args' rett) -> do
        let l1 = length args
        let l2 = length args'
        when (l1 /= l2) (throwError $ InvalidArgCount l1 l2 p)
        sequence_ $ zipWith checkArg args' args
        return rett
      Nothing -> do
        argst <- mapM typecheck args
        if name `elem` builtInNames then
          typecheckBuiltIn p name argst
        else throwError (NoVariable name p)
    where
      checkArg :: TPArgType -> Expr -> TypecheckM ()
      checkArg (TPArgType ak t) expr = do
          et <- typecheck expr
          checkType pos t et
          when (ak == AKRef) checkIfVar
        where
          pos = hasPosition expr
          checkIfVar = case expr of
            EVar _ _ -> return ()
            _ -> throwError $ InvalidRefArg pos

-- Typecheck builtin function application (print)
typecheckBuiltIn :: Pos -> String -> [TPType] -> TypecheckM TPType
typecheckBuiltIn p name args = do
  case name of
    "print" -> do
      when (length args /= 1) $ throwError (InvalidArgCount (length args) 1 p)
      when (not ((head args) `elem` [TPInt, TPString, TPBool]))
        $ throwError (TypecheckError "Invalid argument type for print function" p)
      return TPVoid


instance ToTypecheck [Stmt] where
  typecheck [] = do
    env <- ask
    if hasReturn env then
      return $ expRetType env
    else
      return TPVoid
  typecheck (stmt:stmts) =
    case stmt of
      Empty _ -> rest
      BStmt _ block -> do
        rtype <- typecheck block
        if rtype /= TPVoid then
          local insertHasReturn rest
        else
          rest
      Init p t ident e -> do
        t' <- typecheck t
        e' <- typecheck e
        checkType p t' e'
        local (insertVar ident t') rest
      Ass p ident e -> do
        e' <- typecheck e
        t <- lookupVar ident
        case t of
          Just t' -> checkType p t' e' >> rest
          _ -> let (Ident name) = ident in throwError (NoVariable name p)
      Ret p e -> do
        t <- typecheck e
        env <- ask
        checkType p (expRetType env) t
        local insertHasReturn rest
      SExp p e -> typecheck e >> rest
      NestFn p tdef -> do
        t <- typecheck tdef
        local (insertVar (getTopDefIdent tdef) t) rest
      Break _ -> rest
      Continue _ -> rest
      Cond p block -> do
        rtype <- typecheck block
        if rtype /= TPVoid then
          local insertHasReturn rest
        else
          rest
      While p e block -> do
        e' <- typecheck e
        checkType p TPBool e'
        typecheck block
        rest
    where
      rest = typecheck stmts
    
instance ToTypecheck If where
  typecheck ifStmt = case ifStmt of
    If p e b -> do
      e' <- typecheck e
      checkType p TPBool e'
      typecheck b
      return TPVoid
    IfElse p e b elseBlock -> do
      e' <- typecheck e
      checkType p TPBool e'
      t1 <- typecheck b
      t2 <- typecheck elseBlock
      if ((t1 /= TPVoid) && (t1 == t2)) then
        return t1
      else
        return TPVoid

instance ToTypecheck Else where
  typecheck elseStmt = case elseStmt of
    ElseBlock p b -> typecheck b
    ElseIf p ifStmt -> typecheck ifStmt


instance ToTypecheck Block where
  typecheck (Block p stmts) = typecheck stmts

-- Prepare environment (expected return type) and typecheck the block
typecheckFnBlock :: TPType -> Block -> TypecheckM ()
typecheckFnBlock rtype block = do
  t <- local (\e -> e { hasReturn = False, expRetType = rtype }) (typecheck block)
  when (t == TPVoid) (throwError $ NoReturn (hasPosition block))


instance ToTypecheck TopDef where
  typecheck tdef@(FnDef p ident args rtype block@(Block _ stmts)) = do
    tpArgs <- mapM typecheck args
    tpRtype <- typecheck rtype
    fnType <- fromTopDef tdef
    let newVars = (ident, fnType) : (zip (Prelude.map getArgIdent args) tpArgs)
    let updateEnv env = Prelude.foldl (\e (k, v) -> insertVar k v e) env newVars
    local updateEnv (typecheckFnBlock tpRtype block)
    return fnType

fromTopDef :: TopDef -> TypecheckM TPType
fromTopDef (FnDef _ ident args rtype _) = do
  tpArgTypes <- mapM (fromArgType . argToArgType) args
  tpRtype <- typecheck rtype
  return $ TPFn tpArgTypes tpRtype 

instance ToTypecheck Program where
  typecheck (Program _ tdefs) = populateAndTypecheck tdefs tdefs
    where
      -- First, populate the environment with top definitions
      populateAndTypecheck tdefsAll (tdef:tdefs) = do 
        t <- fromTopDef tdef
        local (insertVar (getTopDefIdent tdef) t) (populateAndTypecheck tdefsAll tdefs)
      -- Next, typecheck blocks and check the type of main function
      populateAndTypecheck tdefsAll [] = do 
        mapM_ typecheck tdefsAll
        mainFn <- lookupVar mainFnIdent
        case mainFn of
          Just (TPFn [] TPInt) -> return TPInt
          _ -> throwError (TypecheckError "Invalid main function or no main function" Nothing)
