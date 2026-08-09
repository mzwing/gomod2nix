module example.com/testreplace

go 1.23

require (
	example.com/depa v1.0.0
	example.com/locallib v0.0.0
)

replace example.com/depa => example.com/depa-fork v1.0.1

replace example.com/locallib => ./locallib
