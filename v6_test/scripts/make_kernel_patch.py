#!/usr/bin/env python3
"""Rebuild the pristine side of the vsi_cam edits and emit a git-appliable patch.

The kernel repo .gitignore's drivers/media/platform/horizon/camsys (vendor tree),
so `git diff` cannot produce the patch. Each edit is a pure insertion except the
sif_handler else-branch, which is recorded as a replace pair.
"""
import difflib
from pathlib import Path

ROOT = Path("/root/code_1.0.20/kernel/drivers/media/platform/horizon/camsys/vsi_cam")
OUT = Path("/root/code_1.0.20/tmp/isp-latency-notice/patches/0001-camsys-sif2isp-queue-atrace.patch")
PREFIX = "drivers/media/platform/horizon/camsys/vsi_cam/"

PAIRS = {
    "include/cam_ctx.h": [
        (
            """int cam_check_datapath(struct cam_ctx *ctx, bool *online);

/*
 * Tracing helper: frame id currently associated with this context's vnode.
 * The native (VIO) build returns the propagated hardware frame id, which is
 * what the SIF->ISP atrace pair uses as its cookie. The legacy v4l2 build has
 * no such propagation and returns 0; its instrumentation stays disabled.
 */
u32 cam_ctx_frame_id(struct cam_ctx *ctx);

#endif /* _CAM_COM_H_ */""",
            """int cam_check_datapath(struct cam_ctx *ctx, bool *online);

#endif /* _CAM_COM_H_ */""",
        )
    ],
    "native/cam_ctx.c": [
        (
            """u32 cam_ctx_frame_id(struct cam_ctx *ctx)
{
	struct vio_subdev *subdev = (struct vio_subdev *)ctx;

	if (!subdev || !subdev->vnode)
		return 0;

	return subdev->vnode->frameid.frame_id;
}

void sif_get_frame_des(struct cam_ctx *ctx)""",
            """void sif_get_frame_des(struct cam_ctx *ctx)""",
        )
    ],
    "v4l2/cam_ctx.c": [
        (
            """void sif_get_frame_des(struct cam_ctx *ctx)
{
}

u32 cam_ctx_frame_id(struct cam_ctx *ctx)
{
	(void)ctx;

	return 0;
}""",
            """void sif_get_frame_des(struct cam_ctx *ctx)
{
}""",
        )
    ],
    "sif/sif_handler.c": [
        (
            """			} else {
				/*
				 * Test-1 anchor A: SIF finished writing the frame and
				 * enqueues it downstream (SIF "write queue"). The async
				 * slice is keyed by the hardware frame id that
				 * sif_set_frame_des() stored at FS; vio_frame_done()
				 * copies it into the frame, so the ISP dequeue side
				 * can close the same cookie.
				 */
				u32 trace_fid = cam_ctx_frame_id(ins->ctx.sink_ctx);

				camsys_atrace_begin("camsys.sif2isp.queue", trace_fid);
				cam_qbuf_irq(buf_ctx, *buf, true);
				camsys_atrace_counter("camsys.sif2isp.enq", trace_fid);
			}""",
            """			} else {
				cam_qbuf_irq(buf_ctx, *buf, true);
			}""",
        )
    ],
    "isp/isp_handler.c": [
        (
            """		buf = cam_dqbuf_irq(ctx->src_ctx[i], true);
		if (!buf)
			return -ENOMEM;

		/*
		 * Test-1 anchor B: ISP actually dequeues the SIF frame from the
		 * shared frame manager (ISP "read queue"). cam_dqbuf_irq() copied
		 * the frame's frameinfo.frameid into the vnode, so this returns
		 * the same id SIF used at enqueue. A matching counter row lets the
		 * analysis join enqueue/dequeue even if a slice pair is lost.
		 */
		{
			u32 trace_fid = cam_ctx_frame_id(ctx->src_ctx[i]);

			camsys_atrace_end("camsys.sif2isp.queue", trace_fid);
			camsys_atrace_counter("camsys.sif2isp.deq", trace_fid);
		}

		node = list_first_entry_or_null(ctx->src_buf_list1,""",
            """		buf = cam_dqbuf_irq(ctx->src_ctx[i], true);
		if (!buf)
			return -ENOMEM;
		node = list_first_entry_or_null(ctx->src_buf_list1,""",
        ),
        (
            """			camsys_atrace_begin("camsys.isp.frame",
					    camsys_atrace_cookie(isp->id,
							isp->next_mi_irq_ctx, false));
			/*
			 * Test-1 secondary anchor: ISP hardware actually starts
			 * reading the frame from DDR. Joined against the SIF
			 * enqueue counter this yields enqueue -> read start,
			 * distinct from enqueue -> software dequeue.
			 */
			if (has_offline(ins->ctx.src_online_stat)) {
				u32 off = get_offline(ins->ctx.src_online_stat);

				camsys_atrace_counter("camsys.isp.fs",
						      cam_ctx_frame_id(ins->ctx.src_ctx[off]));
			}
			isp_mis &= ~BIT(6);""",
            """			camsys_atrace_begin("camsys.isp.frame",
					    camsys_atrace_cookie(isp->id,
							isp->next_mi_irq_ctx, false));
			isp_mis &= ~BIT(6);""",
        ),
    ],
}


def build_patch():
    chunks = []
    for rel, pairs in PAIRS.items():
        cur = (ROOT / rel).read_text()
        rel = PREFIX + rel
        orig = cur
        for new, old in pairs:
            if new not in orig:
                raise SystemExit(f"edit not found in {rel}: {new[:60]!r}")
            orig = orig.replace(new, old, 1)
        diff = difflib.unified_diff(
            orig.splitlines(keepends=True),
            cur.splitlines(keepends=True),
            fromfile=f"a/{rel}",
            tofile=f"b/{rel}",
            n=4,
        )
        body = "".join(diff)
        if not body:
            raise SystemExit(f"no difference for {rel}")
        chunks.append(f"diff --git a/{rel} b/{rel}\n{body}")
    OUT.write_text("".join(chunks))
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    build_patch()
