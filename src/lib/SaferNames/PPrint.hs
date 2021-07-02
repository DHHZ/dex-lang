-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE IncoherentInstances #-}  -- due to `ConRef`
{-# OPTIONS_GHC -Wno-orphans #-}

module SaferNames.PPrint ( pprint, pprintList, asStr , atPrec) where

import GHC.Exts (Constraint)
import Data.Foldable (toList)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import Data.Text.Prettyprint.Doc.Render.Text
import Data.Text.Prettyprint.Doc
import Data.Text (unpack)
import System.IO.Unsafe
import System.Environment

import LabeledItems

import PPrint (PrettyPrec (..), PrecedenceLevel (..), atPrec, pprint,
               prettyFromPrettyPrec, DocPrec)

import SaferNames.NameCore (unsafeCoerceE)
import SaferNames.Name
import SaferNames.Syntax

type PrettyPrecE e = (forall (n::S). PrettyPrec (e n)) :: Constraint

pprintList :: Pretty a => [a] -> String
pprintList xs = asStr $ vsep $ punctuate "," (map p xs)

layout :: LayoutOptions
layout = if unbounded then LayoutOptions Unbounded else defaultLayoutOptions
  where unbounded = unsafePerformIO $ (Just "1"==) <$> lookupEnv "DEX_PPRINT_UNBOUNDED"

asStr :: Doc ann -> String
asStr doc = unpack $ renderStrict $ layoutPretty layout $ doc

p :: Pretty a => a -> Doc ann
p = pretty

pLowest :: PrettyPrec a => a -> Doc ann
pLowest a = prettyPrec a LowestPrec

pApp :: PrettyPrec a => a -> Doc ann
pApp a = prettyPrec a AppPrec

pArg :: PrettyPrec a => a -> Doc ann
pArg a = prettyPrec a ArgPrec

instance Pretty (Block n) where
  pretty (Block _ Empty expr) = group $ line <> pLowest expr
  pretty (Block _ decls expr) = hardline <> prettyLines decls' <> pLowest expr
    where decls' = fromNest decls

fromNest :: Nest b n l -> [b UnsafeMakeS UnsafeMakeS]
fromNest = undefined

prettyLines :: (Foldable f, Pretty a) => f a -> Doc ann
prettyLines xs = foldMap (\d -> p d <> hardline) $ toList xs

instance Pretty (Binder n l) where pretty = undefined

instance Pretty (Expr n) where pretty = prettyFromPrettyPrec
instance PrettyPrec (Expr n) where
  prettyPrec (App f x) =
    atPrec AppPrec $ pApp f <+> pArg x
  prettyPrec (Atom x ) = prettyPrec x
  prettyPrec (Op  op ) = prettyPrec op
  prettyPrec (Hof (For ann (Lam lamExpr))) =
    atPrec LowestPrec $ forStr ann <+> prettyLamHelper lamExpr (PrettyFor ann)
  prettyPrec (Hof hof) = prettyPrec hof
  prettyPrec (Case e alts _) = prettyPrecCase "case" e alts

prettyPrecCase :: PrettyE e => Doc ann -> Atom n -> [AltP e n] -> DocPrec ann
prettyPrecCase name e alts = atPrec LowestPrec $ name <+> p e <+> "of" <>
  nest 2 (hardline <> foldMap (\alt -> prettyAlt alt <> hardline) alts)

prettyAlt :: PrettyE e => AltP e n -> Doc ann
prettyAlt (Abs bs body) = hsep (map prettyBinderNoAnn  bs') <+> "->" <> nest 2 (p body)
  where bs' = fromNest bs

prettyBinderNoAnn :: Binder n l -> Doc ann
prettyBinderNoAnn (b:>_) = p $ show b

instance PrettyPrecE e => Pretty     (Abs Binder e n) where pretty = prettyFromPrettyPrec
instance PrettyPrecE e => PrettyPrec (Abs Binder e n) where
  prettyPrec (Abs binder body) = atPrec LowestPrec $ "\\" <> p binder <> "." <> pLowest body

instance PrettyPrecE e => Pretty (PrimCon (e n)) where pretty = prettyFromPrettyPrec
instance Pretty (PrimCon (Atom n)) where pretty = prettyFromPrettyPrec

instance Pretty (Decl n l) where
  pretty decl = case decl of
    Let ann (Ignore:>_) bound -> p ann <+> pLowest bound
    -- This is just to reduce clutter a bit. We can comment it out when needed.
    -- Let (v:>Pi _)   bound -> p v <+> "=" <+> p bound
    Let ann b rhs -> align $ p ann <+> p b <+> "=" <> (nest 2 $ group $ line <> pLowest rhs)

prettyPiTypeHelper :: PiType n -> Doc ann
prettyPiTypeHelper (Abs (PiBinder binder arr) body) = let
  prettyBinder = case binder of
    Ignore :> a -> pArg a
    _ -> parens $ p binder
  prettyBody = case body of
    Pi subpi -> prettyPiTypeHelper subpi
    _ -> pLowest body
  in prettyBinder <> (group $ line <> p arr <+> prettyBody)

data PrettyLamType n = PrettyLam (Arrow n) | PrettyFor ForAnn

prettyLamHelper :: LamExpr n -> PrettyLamType n -> Doc ann
prettyLamHelper = undefined

instance Pretty (Atom n) where pretty = prettyFromPrettyPrec
instance PrettyPrec (Atom n) where
  prettyPrec atom = case atom of
    Var v -> atPrec ArgPrec $ p v
    Lam lamExpr@(Abs (LamBinder _ TabArrow) _) ->
      atPrec LowestPrec $ "\\for"
      <+> prettyLamHelper lamExpr (PrettyLam TabArrow)
    Lam lamExpr@(Abs (LamBinder _ arr) _) ->
      atPrec LowestPrec $ "\\"
      <> prettyLamHelper lamExpr (unsafeCoerceE (PrettyLam arr))
    Pi piType -> atPrec LowestPrec $ align $ prettyPiTypeHelper piType
    TC  e -> prettyPrec e
    Con e -> prettyPrec e
    Eff e -> atPrec ArgPrec $ p e
    DataCon _ _ _ _ -> undefined
    TypeCon _ _ -> undefined
    LabeledRow items -> prettyExtLabeledItems items (line <> "?") ":"
    Record items -> prettyLabeledItems items (line' <> ",") " ="
    Variant _ label i value -> prettyVariant ls label value where
      ls = LabeledItems $ case i of
            0 -> M.empty
            _ -> M.singleton label $ NE.fromList $ fmap (const ()) [1..i]
    RecordTy items -> prettyExtLabeledItems items (line <> "&") ":"
    VariantTy items -> prettyExtLabeledItems items (line <> "|") ":"
    ACase e alts _ -> prettyPrecCase "acase" e alts
    DataConRef _ _ _ -> undefined
    BoxedRef ptr size (Abs b body) -> atPrec AppPrec $
      "Box" <+> p b <+> "<-" <+> p ptr <+> "[" <> p size <> "]" <+> hardline <> "in" <+> p body
    ProjectElt _ _ -> undefined

prettyExtLabeledItems :: (PrettyPrec a, PrettyPrec b)
  => ExtLabeledItems a b -> Doc ann -> Doc ann -> DocPrec ann
prettyExtLabeledItems (Ext (LabeledItems row) rest) separator bindwith =
  atPrec ArgPrec $ align $ group $ innerDoc
  where
    elems = concatMap (\(k, vs) -> map (k,) (toList vs)) (M.toAscList row)
    fmtElem (label, v) = p label <> bindwith <+> pLowest v
    docs = map fmtElem elems
    final = case rest of
      Just v -> separator <> " ..." <> pArg v
      Nothing -> case length docs of
        0 -> separator
        _ -> mempty
    innerDoc = "{" <> flatAlt " " ""
      <> concatWith (surround (separator <> " ")) docs
      <> final <> "}"

prettyLabeledItems :: PrettyPrec a
  => LabeledItems a -> Doc ann -> Doc ann -> DocPrec ann
prettyLabeledItems items =
  prettyExtLabeledItems $ Ext items (Nothing :: Maybe ())

prettyVariant :: PrettyPrec a
  => LabeledItems () -> Label -> a -> DocPrec ann
prettyVariant labels label value = atPrec ArgPrec $
      "{|" <> left <+> p label <+> "=" <+> pLowest value <+> "|}"
      where left = foldl (<>) mempty $ fmap plabel $ reflectLabels labels
            plabel (l, _) = p l <> "|"

forStr :: ForAnn -> Doc ann
forStr (RegularFor Fwd) = "for"
forStr (RegularFor Rev) = "rof"
forStr ParallelFor      = "pfor"

instance Pretty (EffectRow n) where
  pretty (EffectRow effs tailVar) =
    braces $ hsep (punctuate "," (map p (toList effs))) <> tailStr
    where
      tailStr = case tailVar of
        Nothing -> mempty
        Just v  -> "|" <> p v

instance Pretty (Effect n) where
  pretty eff = case eff of
    RWSEffect rws h -> p rws <+> p h
    ExceptionEffect -> "Except"
    IOEffect        -> "IO"

instance PrettyPrec (Name s n) where prettyPrec = atPrec ArgPrec . pretty
