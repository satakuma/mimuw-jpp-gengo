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


type Env = Map Ident TPType

env0 :: Env
env0 = Map.empty


type TypecheckM a = ReaderT Env (ExceptT TPException IO) a

runTypecheck :: TypecheckM a -> IO (Either TPException a)
runTypecheck tp = runExceptT (runReaderT tp env0)


data TPException
  = TypecheckError String Pos
  | MismatchedType TPType TPType Pos
  | NoVariable String Pos
  | InvalidRefArg Pos
  | InvalidArgCount Data.Int.Int Data.Int.Int Pos
  deriving (Eq, Ord, Read)

instance Show TPException where
  show e =
    case e of
      TypecheckError s p -> "Typecheck error: " ++ s ++ showpos p
      MismatchedType t1 t2 p -> "Mismatched types: " ++ show t1 ++ " vs " ++ show t2 ++ showpos p
      NoVariable s p -> "No variable in scope: " ++ s ++ showpos p
      InvalidRefArg p -> "Invalid expression for a reference argument" ++ showpos p
      InvalidArgCount c1 c2 p -> "Invalid function argument count: " ++ show c1 ++ " vs " ++ show c2 ++ showpos p
    where
      showpos pos = case pos of
        Just p -> " @ " ++ show p
        Nothing -> ""


data TPType
  = TPFn [Arg] TPType
  | TPInt
  | TPBool
  | TPString
  | TPVoid
  deriving (Eq, Ord, Read)

instance Show TPType where
  show t =
    case t of
      TPFn args rtype -> "fn(" ++ intercalate "," (Prelude.map show args) ++ ") -> " ++ show rtype
      TPInt -> "int"
      TPBool -> "bool"
      TPString -> "string"
      TPVoid -> "void"


class ToTypecheck a where
  typecheck :: a -> TypecheckM TPType


instance ToTypecheck (Type' a) where
  typecheck (Int _) = return TPInt
  typecheck (Str _) = return TPString
  typecheck (Bool _) = return TPBool


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
      checkArg :: Arg -> Expr -> TypecheckM ()
      checkArg arg expr =
        let pos = hasPosition expr in
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


-- Check if expressions in return statements have correct type
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
        checkType p expected t
        rest
      NestFn p tdef -> do
        t <- typecheck tdef
        local (Map.insert (getTopDefIdent tdef) t) rest
      Cond p block -> typecheckYieldReturnIf block >> rest
      While p _ (Block _ block) -> typecheckYieldReturn expected block >> rest
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


instance ToTypecheck Program where
  typecheck (Program p []) = do
    mainFn <- lookupVar mainFnIdent
    case mainFn of
      Just (TPFn [] TPInt) -> return TPInt
      _ -> throwError (TypecheckError "Invalid main function or no main function" Nothing)
  typecheck (Program p (tdef:tdefs)) = do
    t <- typecheck tdef
    local (Map.insert (getTopDefIdent tdef) t) (typecheck $ Program p tdefs)
