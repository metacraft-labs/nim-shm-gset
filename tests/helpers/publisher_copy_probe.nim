## Real compiler probe: destructor/copy hooks are inserted after compiles().
import shm_gset/generation_publisher
import generation_policy
var source: GenerationPublisherOwner[TestGenerationPolicy]
when defined(movePublisher):
  var destination = move(source)
else:
  var destination = source
# Both variables remain used, preventing the compiler from inferring a move.
echo source.available, destination.available
