# Renderer throughput (#93 / #94)

## Phase 1 (done)

Skip idle Present on DX12: `presentLastTarget` is a no-op. Composition FLIP keeps the last frame; re-Present was pure cost.

## Phase 2 (done)

Waitable swap chain: `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`, `SetMaximumFrameLatency(1)`, wait in `beginFrame`; `ResizeBuffers` re-passes the flag.

## Phase 3 (next)

`ALLOW_TEARING` + `CheckFeatureSupport(PRESENT_ALLOW_TEARING)` + adaptive `Present(0, ALLOW_TEARING)` vs `Present(1, 0)`. Honor `window-vsync` where applicable.

## Phase 4 (#94)

Viewport scroll: avoid `dirty = .full` on pin change; rotate/reuse rows and dirty only newly exposed rows; optional DX12 row-range buffer sync later.