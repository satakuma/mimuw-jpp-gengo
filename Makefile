interpreter: Gengo.hs AbsGengo.hs ErrM.hs LexGengo.hs ParGengo.hs PrintGengo.hs SkelGengo.hs Typecheck.hs Interpreter.hs
	ghc --make $< -o gengo
	cp ./gengo ./interpreter

bnfc: Gengo.cf
	bnfc -mMakefileBNFC --functor Gengo.cf
	make -f MakefileBNFC
