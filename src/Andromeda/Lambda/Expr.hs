{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
module Andromeda.Lambda.Expr where

import GHC.Stack (errorWithStackTrace)
import Data.Ratio (numerator, denominator)
import Data.String (IsString(..))
import Data.List (intercalate)
import Control.Arrow (second)

import Andromeda.Lambda.Type
import Andromeda.Lambda.Glom
import Andromeda.Lambda.VertexBuffer
import Andromeda.Lambda.GPU

-- | Lambda calculus with HOAS.
data Expr a where
    Var  :: V a -> Expr a
    Lit  :: Lit a -> Expr a
    Lam  :: (Expr a -> Expr b) -> Expr (a -> b)
    (:$) :: Expr (a -> b) -> Expr a -> Expr b
infixl 9 :$

-- | Function composition for 'Expr'.
(~>) :: Expr (b -> c) -> Expr (a -> b) -> Expr (a -> c)
(~>) f g = Lam $ \x -> f :$ (g :$ x)
infixr 9 ~>

instance Show (Expr a) where
    show (Var v) = "Var (" ++ show v ++ ")"
    show (Lit l) = "Lit (" ++ show l ++ ")"
    show (Lam _) = "Lam (...)"
    show (a:$ b) = "(" ++ show a ++ ") :$ (" ++ show b ++ ")"

instance HasGLSL (Expr a) where
    toGLSL (Var (V n _)) = n
    toGLSL (Lit li) = toGLSL li
    toGLSL (Lam f :$ x) = toGLSL $ f x
    toGLSL app@(_ :$ _) =
        let (func, args) = collectArgs app
            argsStr = argsToStr args
        in case func of
            ExprN (Lit li) ->
                case li of
                    UnOp f  -> f ++ assertArgLen args 1 (paren argsStr)
                    BinOp f -> assertArgLen args 2 $
                        paren (toGLSL (head args))
                        ++ " " ++ f ++ " " ++
                        paren (toGLSL (last args))
                    FieldAccess f -> assertArgLen args 1 $
                        paren (toGLSL (head args)) ++ "." ++ f
                    f       -> toGLSL (Lit f) ++ paren argsStr
            ExprN (Var (V n _)) -> n ++ paren argsStr
            ExprN (Lam _) -> --toGLSL (betaReduce app)
                errorWithStackTrace $
                "toGLSL Expr: recieved Lam. Expr must be" ++
                " beta reduced. Use 'betaReduce'."
            ExprN (_:$_) -> errorWithStackTrace
                "toGLSL Expr: matched on an impossible case."
      where
        assertArgLen args len x
            | length args /= len =
                errorWithStackTrace $
                    "Error in 'assertArgLen': wanted " ++ show len ++
                    ", recieved " ++ show (length args) ++ "."
            | otherwise = x
    toGLSL (Lam _) =
        errorWithStackTrace "Error in toGLSL Expr: recieved unapplied Lam."

instance HasType a => IsString (Expr a) where
    fromString name = Var (V name (typeOf (undefined :: a)))
var :: HasType a => String -> Expr a
var = fromString

-- | Structural equality.
instance Eq (Expr a) where
    Var (V n1 _) == Var (V n2 _) = n1 == n2
    Lit l1       == Lit l2       = l1 == l2
    Lam _        == Lam _        = True
    (_ :$ _)     == (_ :$ _)     = True
    _            == _            = False

instance (HasGLSL a, Enum a, Num a) => Enum (Expr a) where
    toEnum = Lit . Literal . toEnum

    fromEnum (Lit (Literal x)) = fromEnum x
    fromEnum _ = errorWithStackTrace
        "fromEnum Expr failed. fromEnum only works on 'Lit (Literal x)'"

    succ = (+1)
    pred = (+(-1))

    enumFrom s = s : enumFrom (succ s)
    enumFromThen s d = s : enumFromThen (s+d) d

instance (Num a, HasGLSL a) => Num (Expr a) where
    fromInteger int =
        Lit . Literal $ (fromInteger int :: a)
    (+) a b = Lit (BinOp "+") :$ a :$ b
    (-) a b = Lit (BinOp "-") :$ a :$ b
    (*) a b = Lit (BinOp "*") :$ a :$ b
    abs x = Lit (Native "abs") :$ x
    signum = errorWithStackTrace "Called signum on 'Expr a'."

instance (Fractional a, HasGLSL a) => Fractional (Expr a) where
    fromRational rat = Lit (BinOp "/") :$
                       (fromInteger (numerator rat) :: Expr Int) :$
                       (fromInteger (denominator rat) :: Expr Int)
    n / d = Lit (BinOp "/") :$ n :$ d

instance (Floating a, HasGLSL a) => Floating (Expr a) where
    pi      = Lit (Literal pi)
    exp  x  = Lit (Native "exp")   :$ x
    log  x  = Lit (Native "log")   :$ x
    sin  x  = Lit (Native "sin")   :$ x
    cos  x  = Lit (Native "cos")   :$ x
    tan  x  = Lit (Native "tan")   :$ x
    asin x  = Lit (Native "asin")  :$ x
    acos x  = Lit (Native "acos")  :$ x
    atan x  = Lit (Native "atan")  :$ x
    sinh x  = Lit (Native "sinh")  :$ x
    cosh x  = Lit (Native "cosh")  :$ x
    tanh x  = Lit (Native "tanh")  :$ x
    asinh x = Lit (Native "asinh") :$ x
    acosh x = Lit (Native "acosh") :$ x
    atanh x = Lit (Native "atanh") :$ x

---------------------------------------
-- Helpers for HasGLSL Expr instance --
---------------------------------------

-- | Existential Expr.
data ExprN = forall a. ExprN (Expr a)
instance HasGLSL ExprN where
    toGLSL (ExprN e) = toGLSL e

collectArgsR :: Expr a -> (ExprN, [ExprN])
collectArgsR (xs :$ x) =
    let (f,as) = collectArgsR xs
    in (f, ExprN x : as)
collectArgsR x = (ExprN x,[])

argList :: Expr a -> String
argList = argsToStr . snd . collectArgs

collectArgs :: Expr a -> (ExprN, [ExprN])
collectArgs = second reverse . collectArgsR

argsToStr :: [ExprN] -> String
argsToStr =  intercalate ", " . map toGLSL

-------------
-- Literal --
-------------

-- | A GLSL Literal. More constructors should only
--   be added for glsl operations with special syntax.
data Lit a where
    Literal :: HasGLSL a => a -> Lit a
    Native  :: String -> Lit a

    BinOp   :: String -> Lit a
    UnOp    :: String -> Lit a

    FieldAccess :: String -> Lit a

    Pair    :: Lit (a -> b -> (a, b))

    LitIn   :: HasVertex a => String -> Type a -> [a] -> Lit a
    LitUnif :: HasVertex a => String -> Type a ->  a  -> Lit a

    Fetch   :: String -> Type a -> Lit a
    Unif    :: String -> Type a -> Lit a

instance Show (Lit a) where
    show (Literal l) = "Literal (" ++ toGLSL l ++ ")"
    show (Native  n) = "Native (" ++ n ++ ")"
    show (BinOp b) = "BinOp (" ++ b ++ ")"
    show (UnOp u) = "UnOp (" ++ u ++ ")"
    show (FieldAccess f) = "FieldAccess " ++ f
    show Pair = "Pair"
    show LitIn{} = "LitIn"
    show LitUnif{} = "LitUnif"
    show (Fetch n _) = "Fetch " ++ show n
    show (Unif  n _) = "Unif "  ++ show n

instance HasGLSL (Lit a) where
    toGLSL (Literal a) = toGLSL a
    toGLSL (Native s) = s
    toGLSL (BinOp s) = s
    toGLSL (UnOp s) = s
    toGLSL (FieldAccess f) = f
    toGLSL Pair = errorWithStackTrace "toGLSL Pair"
    toGLSL LitIn{} = errorWithStackTrace "toGLSL LitIn"
    toGLSL LitUnif{} = errorWithStackTrace "toGLSL LitUnif"
    toGLSL (Fetch n _) = n
    toGLSL (Unif  n _) = n

instance Eq (Lit a) where
    Literal     _ == Literal     _ = True
    Native      a == Native      b = a == b
    BinOp       a == BinOp       b = a == b
    UnOp        a == UnOp        b = a == b
    FieldAccess a == FieldAccess b = a == b
    Pair          == Pair          = True
    _             == _             = False

-----------------------
-- Reduction of Expr --
-----------------------

-- | Beta reduce an 'Expr' by applying all
--   'Lam's, where possible. All Exprs should
--   be beta-reduced before being used.
betaReduce :: Expr a -> Expr a
betaReduce (Lam f :$ x) = betaReduce $ f (betaReduce x)
betaReduce (f :$ x)     = betaReduce' $ betaReduce f :$ betaReduce x
  where
    betaReduce' (Lam f' :$ x') = betaReduce $ f' (betaReduce x')
    betaReduce' (f'     :$ x') = betaReduce f' :$ betaReduce x'
    betaReduce' x'             = x'
betaReduce v@Var{} = v
betaReduce l@Lit{} = l
betaReduce l@Lam{} = l

-----------
-- Utils --
-----------

inn :: HasVertex a => String -> [a] -> Expr a
inn name xs = Lit $ LitIn name guessTy xs

uniform :: HasVertex a => String -> a -> Expr a
uniform name x = Lit $ LitUnif name guessTy x

lit :: HasGLSL a => a -> Expr a
lit = Lit . Literal

typeOfE :: HasType a => Expr a -> Type a
typeOfE _ = typeOf undefined

paren :: String -> String
paren str = "(" ++ str ++ ")"

------------------
-- Experimental --
------------------

{-
instance GPU (Expr Float) where
    type CPU (Expr Float) = Float
    toGPU = Lit . Literal

instance VertexInput (Expr Float) where
    bufferData [] = EmptyStream
    bufferData xs = PrimitiveStream xs $ toGPU (head xs)
-}
