interpreter: Gengo.hs AbsGengo.hs ErrM.hs LexGengo.hs ParGengo.hs PrintGengo.hs SkelGengo.hs
	ghc --make $< -o gengo

bnfc: Gengo.cf
	bnfc -mMakefileBNFC --functor Gengo.cf
	make -f MakefileBNFC
