# Interpreter języka Gengo 

Tymoteusz Wiśniewski (418404)

## Język 

Język nazwałem "Gengo", a pliki źródłowe tego języka mają rozszerzenie ".gg".
W katalogu `examples/` są przykładowe programy pokazujące funkcjonalności języka.

Gramatyka znajduje się w pliku `Gengo.cf`, opiera się na gramatyce Latte 
pobranej ze strony dr Benke. Nie posiada konfliktów.

## Szczególne cechy

* Funkcje definiuje się za pomocą składni `fn name(typ1 id1, typ2 id2, ..., typn idn) -> typr { ... }`,
  gdzie typy `typ1, ..., typn` to typy przyjmowanych argumentów a `typr` to typ zwracany.
  Każda funkcja musi zwracać jakąś wartość. Jeśli sterowanie wewnątrz funkcji dojdzie do końca bloku,
  nie spotykając instrukcji `return` interpreter zgłosi błąd.

* Język wspiera przekazywanie argumentów przez zmienną; aby przekazać argument przez zmienną należy
  użyć typu z ampersandem, np. `fn f(int& x) -> int`. Przykład użycia znajduje się w `examples/fnarg.gg`.

* Przy deklaracji zmiennych trzeba je od razu zainicjalizować. 

* `print` jest traktowany jako funkcja wbudowana. Można ją nadpisać własną funkcją print,
  ale ryzykuje się wtedy brakiem komunikacji ze światem.

## Generatory

Generatory definiuje się tak samo jak funkcje, tylko za pomocą słowa kluczowego `gn`.
Sygnatura `gn generator(typ1 id1, typ2 id2, typ3 id3) -> typg` mówi, że do stworzenia
generatora potrzebne są trzy argumenty typów `typ1`, `typ2`, `typ3`, a po stworzeniu
generatora za pomocą `generator(a, b, c)` otrzymamy generator typu `@(typg)`, który
będzie generować wartości typu `typg`. Na obiektach typu `@(typg)` można wywoływać
wbudowaną funkcję `next()` aby otrzymać generowane wartości. W przypadku gdy generator
się wyczerpie, tzn sterowanie wewnątrz generatora dojdzie do końca bloku, zostanie
wygenerowany błąd interpretera.

Generatora można także używać wewnątrz pętli for za pomocą składni `for x in (gen) { ... }`,
gdzie `gen` jest typu `@(typg)`. Na początku każdego obrotu pętli interpreter wykona 
`next(gen)` i zapisze wygenerowaną wartość w zmiennej `x` (a więc `x` jest typu `typg`).
Jeśli wewnątrz pętli for generator się wyczerpie, interpreter obsłuży ten błąd i wyjdzie z pętli.

Przykład użycia znajduje się w `examples/generator.gg`.

## Statyczne wiązanie

Język Gengo wspiera zagnieżdżone definicje funkcji oraz przesłanianie identyfikatorów ze statycznym wiązaniem,
dokładnie tak jak było to opisane na spotkaniu.