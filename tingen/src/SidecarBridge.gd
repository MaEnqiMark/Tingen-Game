extends Node
## The single seam between the substrate and the LLM brain (autoload `SidecarBridge`).
## Holds one active SidecarClient — a MockSidecar by default so the game and CI run with
## zero network/API. The agent runtime (a later plan) calls `propose(snapshots)` here and
## nowhere else; swapping in the real HttpSidecar is a one-line `set_client` change.

var client: SidecarClient = null

func _ready() -> void:
	if client == null:
		client = MockSidecar.new()

func set_client(c: SidecarClient) -> void:
	client = c

func is_ready() -> bool:
	return client != null and client.is_ready()

func propose(snapshots: Array) -> Array:
	if client == null:
		return []
	return client.propose(snapshots)
