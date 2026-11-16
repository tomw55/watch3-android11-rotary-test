#!/usr/bin/env python3
"""Samsung 4.9 Binder Android 11 security-context backport (after stage 1).
Strict anchors: fail closed if the pinned source changes.
"""
from pathlib import Path
import difflib

binder = Path("drivers/android/binder.c")
uapi = Path("include/uapi/linux/android/binder.h")

def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one anchor; found {count}: {old[:110]!r}")
    return text.replace(old, new, 1)

def emit(path, before, after):
    diff = ''.join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile='a/' + str(path), tofile='b/' + str(path)))
    print(diff, end='')
    path.write_text(after)

before = uapi.read_text()
s = before
s = replace_once(s,
    "struct binder_transaction_data_sg {",
    """struct binder_transaction_data_secctx {
	struct binder_transaction_data transaction_data;
	binder_uintptr_t secctx;
};

struct binder_transaction_data_sg {""")
s = replace_once(s,
    "\tBR_REPLY = _IOR('r', 3, struct binder_transaction_data),",
    """	BR_REPLY = _IOR('r', 3, struct binder_transaction_data),
	BR_TRANSACTION_SEC_CTX = _IOR('r', 2,
					struct binder_transaction_data_secctx),""")
emit(uapi, before, s)

before = binder.read_text()
s = before
s = replace_once(s,
    "\tkuid_t\tsender_euid;\n",
    "\tkuid_t\tsender_euid;\n\tbinder_uintptr_t security_ctx;\n")
s = replace_once(s,
    "\tint t_debug_id = atomic_inc_return(&binder_last_id);",
    """	int t_debug_id = atomic_inc_return(&binder_last_id);
	char *secctx = NULL;
	u32 secctx_len = 0;
	size_t secctx_aligned = 0;
	binder_size_t secctx_offset = 0;
	bool add_secctx = false;""")
s = replace_once(s,
    "\ttrace_binder_transaction(reply, t, target_node);\n\n\tt->buffer = binder_alloc_new_buf(",
    """	trace_binder_transaction(reply, t, target_node);

	/* Only transactions to nodes explicitly requesting the sender
	 * context carry a security context. Replies do not.
	 */
	add_secctx = !reply && target_node && target_node->txn_security_ctx;
	if (add_secctx) {
		u32 secid = 0;

		security_task_getsecid(proc->tsk, &secid);
		ret = security_secid_to_secctx(secid, &secctx, &secctx_len);
		if (ret || !secctx || !secctx_len) {
			return_error = BR_FAILED_REPLY;
			return_error_param = ret ? ret : -EINVAL;
			return_error_line = __LINE__;
			goto err_alloc_tcomplete_failed;
		}
		secctx_aligned = ALIGN((size_t)secctx_len, sizeof(u64));
		if (secctx_aligned < secctx_len ||
		    extra_buffers_size > (binder_size_t)-1 - secctx_aligned) {
			return_error = BR_FAILED_REPLY;
			return_error_param = -EOVERFLOW;
			return_error_line = __LINE__;
			goto err_secctx;
		}
		secctx_offset = extra_buffers_size;
		extra_buffers_size += secctx_aligned;
	}

	t->buffer = binder_alloc_new_buf(""")
s = replace_once(s,
    "\t\tt->buffer = NULL;\n\t\tgoto err_binder_alloc_buf_failed;",
    """		t->buffer = NULL;
		goto err_secctx;""")
s = replace_once(s,
    "\tsg_buf_end = sg_bufp + extra_buffers_size;\n\toff_min = 0;",
    """	sg_buf_end = sg_bufp + extra_buffers_size;
	if (add_secctx) {
		u8 *ctx_dest = sg_bufp + secctx_offset;

		memcpy(ctx_dest, secctx, secctx_len);
		t->security_ctx = (binder_uintptr_t)
			((uintptr_t)ctx_dest +
			 binder_alloc_get_user_buffer_offset(&target_proc->alloc));
		security_release_secctx(secctx, secctx_len);
		secctx = NULL;
		/* Scatter/gather objects must not overwrite the context. */
		sg_buf_end = ctx_dest;
	}
	off_min = 0;""")
s = replace_once(s,
    "err_binder_alloc_buf_failed:\n\tkfree(tcomplete);",
    """err_secctx:
	if (secctx)
		security_release_secctx(secctx, secctx_len);
err_binder_alloc_buf_failed:
	kfree(tcomplete);""")
s = replace_once(s,
    "\t\tstruct binder_transaction_data tr;\n\t\tstruct binder_work *w = NULL;",
    """		struct binder_transaction_data tr;
		struct binder_transaction_data_secctx tr_secctx;
		struct binder_work *w = NULL;""")
s = replace_once(s,
    "\t\tif (end - ptr < sizeof(tr) + 4) {",
    "\t\tif (end - ptr < sizeof(tr_secctx) + sizeof(uint32_t)) {")
s = replace_once(s,
    "\t\t\tcmd = BR_TRANSACTION;\n\t\t} else {",
    """			cmd = t->security_ctx ?
				BR_TRANSACTION_SEC_CTX : BR_TRANSACTION;
		} else {""")
s = replace_once(s,
    """		if (copy_to_user(ptr, &tr, sizeof(tr))) {
			if (t_from)
				binder_thread_dec_tmpref(t_from);
			return -EFAULT;
		}
		ptr += sizeof(tr);""",
    """		if (cmd == BR_TRANSACTION_SEC_CTX) {
			tr_secctx.transaction_data = tr;
			tr_secctx.secctx = t->security_ctx;
			if (copy_to_user(ptr, &tr_secctx, sizeof(tr_secctx))) {
				if (t_from)
					binder_thread_dec_tmpref(t_from);
				return -EFAULT;
			}
			ptr += sizeof(tr_secctx);
		} else {
			if (copy_to_user(ptr, &tr, sizeof(tr))) {
				if (t_from)
					binder_thread_dec_tmpref(t_from);
				return -EFAULT;
			}
			ptr += sizeof(tr);
		}""")
s = replace_once(s,
    "if (cmd == BR_TRANSACTION && !(t->flags & TF_ONE_WAY)) {",
    "if ((cmd == BR_TRANSACTION || cmd == BR_TRANSACTION_SEC_CTX) &&\n\t    !(t->flags & TF_ONE_WAY)) {")
emit(binder, before, s)
