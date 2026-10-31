## Test-local identity policy; only the extra word/version differ from default.
type TestGenerationPolicy* = object
proc keyFormatVersion*(_: typedesc[TestGenerationPolicy]): uint32 = 0x54455301'u32
proc extraControlWords*(_: typedesc[TestGenerationPolicy]): int = 1

type OtherGenerationPolicy* = object
proc keyFormatVersion*(_: typedesc[OtherGenerationPolicy]): uint32 = 0x54455302'u32
proc extraControlWords*(_: typedesc[OtherGenerationPolicy]): int = 1
