#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/samsung-virt-evidence"
mkdir -p "$out"
stage=source
trap 'rc=$?; printf "stage=%s exit=%s\n" "$stage" "$rc" > "$out/result.txt"' EXIT
work=$(mktemp -d)
cd "$work"
curl -fL --retry 3 -o source.zip \
  https://github.com/tomw55/watch3-android11-rotary-test/releases/download/kernel-source-4.9.59/kernel_samsung_galileo-master.zip
echo '1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f  source.zip' | sha256sum -c - | tee "$out/source-hash.txt"
unzip -q source.zip
cd kernel_samsung_galileo-master
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    {
        echo '=== dm-crypt 4096-byte support and IV handling ==='
        grep -nE 'sector_size|sector_shift|crypt_iv_plain64_gen|crypt_ctr_optional|crypt_convert_block_skcipher' drivers/md/dm-crypt.c || true
        echo '=== crypt_iv_plain64_gen function ==='
        sed -n '/^static .*crypt_iv_plain64_gen(/,/^}/p' drivers/md/dm-crypt.c
        echo '=== crypt_ctr_optional function ==='
        sed -n '/^static .*crypt_ctr_optional(/,/^}/p' drivers/md/dm-crypt.c
        echo '=== crypt_target declaration and linkage ==='
        grep -n -B 3 -A 35 'crypt_target = ' drivers/md/dm-crypt.c || true
        echo '=== device-mapper target API ==='
        grep -n -A 75 '^struct target_type {' include/linux/device-mapper.h || true
        grep -n 'dm_set_target_max_io_len' include/linux/device-mapper.h drivers/md/dm-crypt.c || true
    } > "$out/dm-crypt-api-inspection.txt" 2>&1
fi
# Capture the actual Samsung bio ownership and crypto interfaces before any
# dm-default-key implementation is allowed to advertise a working target.
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    {
        echo '=== Samsung dm-crypt bio lifecycle and crypto primitives ==='
        grep -nE 'bio_clone_fast|bio_alloc_bioset|bio_endio|bi_end_io|bi_private|generic_make_request|crypto_(alloc_skcipher|skcipher_encrypt|skcipher_decrypt)|skcipher_request_alloc|mempool_create_page_pool|alloc_workqueue|dm_target_offset' drivers/md/dm-crypt.c || true
        echo '=== Samsung device-mapper bio ownership conventions ==='
        grep -nE 'DM_MAPIO_SUBMITTED|DM_MAPIO_REMAPPED|DM_MAPIO_KILL|bio_clone_fast|bio_endio|dm_target_offset' drivers/md/dm.c | head -110 || true
        echo '=== Relevant declarations ==='
        grep -nE 'bio_clone_fast|bio_alloc_bioset|bio_endio|generic_make_request' include/linux/bio.h include/linux/blkdev.h || true
        grep -nE 'crypto_alloc_skcipher|crypto_skcipher_encrypt|crypto_skcipher_decrypt' include/crypto/skcipher.h || true
        grep -nE 'dm_get_device|dm_put_device|dm_target_offset|dm_set_target_max_io_len' include/linux/device-mapper.h || true
        echo '=== QEMU-only patch availability ==='
        find "$repo/patches/ci-compat" -maxdepth 1 -name '*.patch' -printf '%f\\n' | sort
    } > "$out/dm-default-key-stage1-api-preflight.txt" 2>&1
fi
# Preserve full Samsung DM completion-path bodies for review before adding
# a target that assumes responsibility for an incoming DM clone bio.
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    {
        echo '=== Samsung dm.c: clone_endio ==='
        sed -n '/^static .*clone_endio(/,/^}/p' drivers/md/dm.c
        echo '=== Samsung dm.c: __map_bio ==='
        sed -n '/^static .*__map_bio(/,/^}/p' drivers/md/dm.c
        echo '=== Samsung dm.c: dec_pending ==='
        sed -n '/^static .*dec_pending(/,/^}/p' drivers/md/dm.c
        echo '=== Relevant io_count and error paths with context ==='
        grep -n -C 7 -E 'DM_MAPIO_SUBMITTED|DM_MAPIO_REMAPPED|clone_endio|dec_pending\\(|io_count|bi_error' drivers/md/dm.c | head -350 || true
    } > "$out/dm-default-key-dm-completion-contract.txt" 2>&1
fi
# Record source-level dm-default-key support before attempting config changes.
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    {
        echo '=== Samsung 4.9.59 dm-default-key source inventory ==='
        find drivers/md -maxdepth 1 -iname '*default*key*' -print
        echo '=== Kconfig and Makefile references ==='
        grep -nE 'DM_DEFAULT_KEY|BLK_INLINE_ENCRYPTION|INLINE_ENCRYPTION_FALLBACK' drivers/md/Kconfig drivers/md/Makefile || true
        echo '=== Driver constructor and argument parsing (if present) ==='
        if [[ -f drivers/md/dm-default-key.c ]]; then
            grep -nE 'default_key_ctr|argc|argv|sector_size|iv_large_sectors|allow_discards|target_type' drivers/md/dm-default-key.c || true
            sed -n '1,260p' drivers/md/dm-default-key.c
        else
            echo 'drivers/md/dm-default-key.c: ABSENT'
        fi
        echo '=== Other default-key implementation references ==='
        grep -Rnl -E 'default-key|DM_DEFAULT_KEY' drivers/md --include='*.c' --include='Kconfig' --include='Makefile' | head -50 || true
    } > "$out/dm-default-key-source-inspection.txt" 2>&1
fi
rm -f scripts/basic/{fixdep,.fixdep.cmd} \
  scripts/kconfig/{conf,conf.o,zconf.tab.o,.conf.cmd,.conf.o.cmd,.zconf.tab.o.cmd}
stage=config
export ARCH=arm64
export CROSS_COMPILE
CROSS_COMPILE=$("$repo/scripts/install-kernel-toolchain.sh" "$work/toolchain")
{
    "${CROSS_COMPILE}gcc" --version
    "${CROSS_COMPILE}ld" --version
    aarch64-linux-gnu-gcc --version
    qemu-system-aarch64 --version
    checkpolicy -V
} > "$out/tools.txt"
cp "$repo/ci/samsung-virt/test.conf" "$out/"
# Use the existing accepted and compiler compatibility series, in order.
for patchfile in "$repo"/patches/{accepted,ci-compat}/*.patch; do
    patch --batch --fuzz=0 -p1 < "$patchfile"
done 2>&1 | tee "$out/patches.log"
# Experimental QEMU-only driver compile gate.  Never install on a physical watch.
# Stage after the accepted patches so the source sees the actual Samsung APIs.
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    stage=dm-default-key-integration
    test ! -e drivers/md/dm-default-key.c
    cp "$repo/scripts/dm-default-key-review-draft.c" drivers/md/dm-default-key.c
    # QEMU-only core dispatch probe, inserted into the exact kernel tree built here.
    # Fail at build time if Samsung's dm.c layout changes rather than silently
    # producing another kernel without the intended instrumentation.
    python3 - <<'PYDMTRACE'
from pathlib import Path
import re
p = Path("drivers/md/dm.c")
s = p.read_text()
pattern = r'(static void __map_bio\s*\([^)]*\)\s*\{)(.*?)(\n\s*(?:if\s*\(|[A-Za-z_]\w*\s*\(|return\s*;))'
matches = list(re.finditer(pattern, s, re.S))
if len(matches) != 1:
    raise SystemExit("Expected exactly one Samsung dm.c __map_bio body; found %d" % len(matches))
m = matches[0]
# Place the trace after declarations and before the first executable statement.
# Linux 4.9 builds with -Werror=declaration-after-statement.
probe = '\n    pr_warn("dm-core __map_bio entered\\n");'
s = s[:m.start(3)] + probe + s[m.start(3):]
p.write_text(s)
print("Installed QEMU-only dm-core __map_bio entry probe")
PYDMTRACE
    if ! grep -Fq 'dm-default-key map_entry:' drivers/md/dm-default-key.c; then
        echo 'Missing target map_entry trace in staged driver' >&2
        exit 1
    fi
    cat >> drivers/md/Kconfig <<'DK_KCONFIG'

config DM_DEFAULT_KEY
    bool "Android default-key target (QEMU experiment)"
    depends on BLK_DEV_DM
    select CRYPTO_SKCIPHER
    select CRYPTO_XTS
    help
      Standalone AES-XTS default-key device-mapper target.
DK_KCONFIG
    printf '\nobj-$(CONFIG_DM_DEFAULT_KEY) += dm-default-key.o\n' >> drivers/md/Makefile
    echo 'Staged experimental dm-default-key driver for compile verification' | tee "$out/dm-default-key-integration.txt"
fi
# Generic CPU hotplug has a Samsung header include but uses none of its declarations.
# Remove that dependency only in this disposable non-Exynos source tree.
grep -Fxq '#include <soc/samsung/exynos-powermode.h>' kernel/cpu.c
sed -i '\|^#include <soc/samsung/exynos-powermode.h>$|d' kernel/cpu.c
# No graphics are needed for this serial-only guest. Samsung's unconditional
# GPU entry otherwise expects arm/built-in.o even with Mali deselected.
grep -Eq '^obj-y[[:space:]]*\+=[[:space:]]*gpu/[[:space:]]*$' drivers/Makefile
if [[ ${DRM_BUFFER_GATE:-0} == 1 ]]; then
    # The archive has no gpu/arm/Makefile. Keep generic DRM/VGA only.
    grep -Fq 'drm/ vga/ arm/ exynos/' drivers/gpu/Makefile
    sed -i 's@drm/ vga/ arm/ exynos/@drm/ vga/@' drivers/gpu/Makefile
    echo "Retained generic DRM GPU subtree for the disposable buffer gate."
else
    sed -i -E '/^obj-y[[:space:]]*\+=[[:space:]]*gpu\/[[:space:]]*$/d' drivers/Makefile
    echo "Excluded the GPU subtree from this headless virt build."
fi
# The schedutil object owns this sysctl variable. Do not advertise the
# control when the guest does not build that governor into the kernel.
python3 - <<'PYFIX'
from pathlib import Path
path = Path("kernel/sysctl.c")
source = path.read_text()
old = '#ifndef CONFIG_CPU_FREQ_DEFAULT_GOV_TIZEN_MORION\n\t{\n\t\t.procname\t= "sched_rt_remove_ratio_for_freq",'
new = old.replace(
    "#ifndef CONFIG_CPU_FREQ_DEFAULT_GOV_TIZEN_MORION",
    "#if defined(CONFIG_CPU_FREQ_GOV_SCHEDUTIL) && !defined(CONFIG_CPU_FREQ_DEFAULT_GOV_TIZEN_MORION)",
)
if source.count(old) != 1:
    raise SystemExit("Expected Samsung schedutil sysctl guard exactly once")
path.write_text(source.replace(old, new))
PYFIX
if [[ -n ${REFERENCE_POLICY:-} ]]; then
    # Report the full write result from the kernel. Android's reference
    # policy need not permit this native PID 1 to write to the console.
    python3 - <<'PYLOAD'
from pathlib import Path
p = Path("security/selinux/selinuxfs.c")
s = p.read_text()
old = "\tvfree(data);\n\treturn length;\n}\n\nstatic const struct file_operations sel_load_ops"
assert s.count(old) == 1
new = old.replace(
    "\treturn length;",
    '\tpr_info("virt-policy: load result=%zd bytes=%zu enforcing=%d\\n", length, count, selinux_enforcing);'
    "\n\treturn length;",
)
p.write_text(s.replace(old, new))
PYLOAD
fi
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    # The compat conversion helper can be unused when ELF core notes are absent.
    # Inline keeps it available to callers without changing the warning policy.
    grep -Eq '^static void cputime_to_compat_timeval\(' fs/compat_binfmt_elf.c
    sed -i 's/^static void cputime_to_compat_timeval(/static inline void cputime_to_compat_timeval(/' \
        fs/compat_binfmt_elf.c
fi
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    stage=binder_backport_check
    # Upstream ec74136ded792deed80780a2f8baf3521eeb72f9, Todd Kjos.
    # Samsung-specific review v2; apply only to the disposable integration tree.
    cat > "$out/binder-security-context.patch" <<'BINDER_REVIEW_V2'
diff --git a/drivers/android/binder.c b/drivers/android/binder.c
index eb11e13..c6d0901 100644
--- a/drivers/android/binder.c
+++ b/drivers/android/binder.c
@@ -398,6 +398,7 @@ struct binder_node {
 		u8 sched_policy:2;
 		u8 inherit_rt:1;
 		u8 accept_fds:1;
+		u8 txn_security_ctx:1;
 		u8 min_priority;
 	};
 	bool has_async_transaction;
@@ -544,6 +545,8 @@ struct binder_priority {
  * Bookkeeping structure for binder processes
  */
 struct binder_proc {
+	/* Pinned for the lifetime of this Binder file. */
+	const struct cred *cred;
 	struct hlist_node proc_node;
 	struct rb_root threads;
 	struct rb_root nodes;
@@ -653,6 +656,7 @@ struct binder_transaction {
 	struct binder_priority	saved_priority;
 	bool    set_priority_called;
 	kuid_t	sender_euid;
+	binder_uintptr_t security_ctx;
 	/**
 	 * @lock:  protects @from, @to_proc, and @to_thread
 	 *
@@ -1302,6 +1306,7 @@ static struct binder_node *binder_init_node_ilocked(
 		FLAT_BINDER_FLAG_SCHED_POLICY_SHIFT;
 	node->min_priority = to_kernel_prio(node->sched_policy, priority);
 	node->accept_fds = !!(flags & FLAT_BINDER_FLAG_ACCEPTS_FDS);
+	node->txn_security_ctx = !!(flags & FLAT_BINDER_FLAG_TXN_SECURITY_CTX);
 	node->inherit_rt = !!(flags & FLAT_BINDER_FLAG_INHERIT_RT);
 	spin_lock_init(&node->lock);
 	INIT_LIST_HEAD(&node->work.entry);
@@ -2404,7 +2409,7 @@ static int binder_translate_binder(struct flat_binder_object *fp,
 		ret = -EINVAL;
 		goto done;
 	}
-	if (security_binder_transfer_binder(proc->tsk, target_proc->tsk)) {
+	if (security_binder_transfer_binder(proc->cred, target_proc->cred)) {
 		ret = -EPERM;
 		goto done;
 	}
@@ -2450,7 +2455,7 @@ static int binder_translate_handle(struct flat_binder_object *fp,
 				  proc->pid, thread->pid, fp->handle);
 		return -EINVAL;
 	}
-	if (security_binder_transfer_binder(proc->tsk, target_proc->tsk)) {
+	if (security_binder_transfer_binder(proc->cred, target_proc->cred)) {
 		ret = -EPERM;
 		goto done;
 	}
@@ -2534,7 +2539,7 @@ static int binder_translate_fd(int fd,
 		ret = -EBADF;
 		goto err_fget;
 	}
-	ret = security_binder_transfer_file(proc->tsk, target_proc->tsk, file);
+	ret = security_binder_transfer_file(proc->cred, target_proc->cred, file);
 	if (ret < 0) {
 		ret = -EPERM;
 		goto err_security;
@@ -2805,6 +2810,11 @@ static void binder_transaction(struct binder_proc *proc,
 	binder_size_t last_fixup_min_off = 0;
 	struct binder_context *context = proc->context;
 	int t_debug_id = atomic_inc_return(&binder_last_id);
+	char *secctx = NULL;
+	u32 secctx_len = 0;
+	size_t alloc_extra = extra_buffers_size;
+	size_t context_space = 0;
+	size_t data_aligned, offsets_aligned;
 
 	e = binder_transaction_log_add(&binder_transaction_log);
 	e->debug_id = t_debug_id;
@@ -2913,8 +2923,8 @@ static void binder_transaction(struct binder_proc *proc,
 			goto err_dead_binder;
 		}
 		e->to_node = target_node->debug_id;
-		if (security_binder_transaction(proc->tsk,
-						target_proc->tsk) < 0) {
+		if (security_binder_transaction(proc->cred,
+						target_proc->cred) < 0) {
 			return_error = BR_FAILED_REPLY;
 			return_error_param = -EPERM;
 			return_error_line = __LINE__;
@@ -3005,7 +3015,7 @@ static void binder_transaction(struct binder_proc *proc,
 		t->from = thread;
 	else
 		t->from = NULL;
-	t->sender_euid = task_euid(proc->tsk);
+	t->sender_euid = proc->cred->euid;
 	t->to_proc = target_proc;
 	t->to_thread = target_thread;
 	t->code = tr->code;
@@ -3020,10 +3030,39 @@ static void binder_transaction(struct binder_proc *proc,
 		t->priority = target_proc->default_priority;
 	}
 
+	if (target_node && target_node->txn_security_ctx) {
+		u32 secid;
+
+		security_cred_getsecid(proc->cred, &secid);
+		ret = security_secid_to_secctx(secid, &secctx, &secctx_len);
+		if (ret)
+			goto err_secctx;
+		if (!secctx || !secctx_len || !IS_ALIGNED(extra_buffers_size, sizeof(u64)) ||
+		    secctx_len > SIZE_MAX - (sizeof(u64) - 1)) {
+			ret = -EINVAL;
+			goto err_secctx;
+		}
+		context_space = ALIGN((size_t)secctx_len, sizeof(u64));
+		if (alloc_extra > SIZE_MAX - context_space ||
+		    tr->data_size > SIZE_MAX - (sizeof(void *) - 1) ||
+		    tr->offsets_size > SIZE_MAX - (sizeof(void *) - 1)) {
+			ret = -EOVERFLOW;
+			goto err_secctx;
+		}
+		alloc_extra += context_space;
+		data_aligned = ALIGN(tr->data_size, sizeof(void *));
+		offsets_aligned = ALIGN(tr->offsets_size, sizeof(void *));
+		if (data_aligned > SIZE_MAX - offsets_aligned ||
+		    alloc_extra > SIZE_MAX - data_aligned - offsets_aligned) {
+			ret = -EOVERFLOW;
+			goto err_secctx;
+		}
+	}
+
 	trace_binder_transaction(reply, t, target_node);
 
 	t->buffer = binder_alloc_new_buf(&target_proc->alloc, tr->data_size,
-		tr->offsets_size, extra_buffers_size,
+		tr->offsets_size, alloc_extra,
 		!reply && (t->flags & TF_ONE_WAY));
 	if (IS_ERR(t->buffer)) {
 		/*
@@ -3083,6 +3122,15 @@ static void binder_transaction(struct binder_proc *proc,
 	off_end = (void *)off_start + tr->offsets_size;
 	sg_bufp = (u8 *)(PTR_ALIGN(off_end, sizeof(void *)));
 	sg_buf_end = sg_bufp + extra_buffers_size;
+	if (secctx) {
+		/* Only the original SG range is available to userspace objects. */
+		memset(sg_buf_end, 0, context_space);
+		memcpy(sg_buf_end, secctx, secctx_len);
+		t->security_ctx = (uintptr_t)sg_buf_end +
+			binder_alloc_get_user_buffer_offset(&target_proc->alloc);
+		security_release_secctx(secctx, secctx_len);
+		secctx = NULL;
+	}
 	off_min = 0;
 	for (; offp < off_end; offp++) {
 		struct binder_object_header *hdr;
@@ -3297,7 +3345,14 @@ err_copy_data_failed:
 	target_node = NULL;
 	t->buffer->transaction = NULL;
 	binder_alloc_free_buf(&target_proc->alloc, t->buffer);
+	goto err_binder_alloc_buf_failed;
+err_secctx:
+	return_error = BR_FAILED_REPLY;
+	return_error_param = ret;
+	return_error_line = __LINE__;
 err_binder_alloc_buf_failed:
+	if (secctx)
+		security_release_secctx(secctx, secctx_len);
 	kfree(tcomplete);
 	binder_stats_deleted(BINDER_STAT_TRANSACTION_COMPLETE);
 err_alloc_tcomplete_failed:
@@ -3356,6 +3411,39 @@ err_invalid_target_handle:
 	}
 }
 
+/* Release a delivered buffer, or roll back a delivery before userspace owns it. */
+static void binder_free_received_buffer(struct binder_proc *proc,
+					struct binder_buffer *buffer,
+					binder_size_t *failed_at)
+{
+	if (buffer->transaction) {
+		buffer->transaction->buffer = NULL;
+		buffer->transaction = NULL;
+	}
+	if (buffer->async_transaction && buffer->target_node) {
+		struct binder_node *buf_node;
+		struct binder_work *w;
+
+		buf_node = buffer->target_node;
+		binder_node_inner_lock(buf_node);
+		BUG_ON(!buf_node->has_async_transaction);
+		BUG_ON(buf_node->proc != proc);
+		w = binder_dequeue_work_head_ilocked(
+				&buf_node->async_todo);
+		if (!w) {
+			buf_node->has_async_transaction = 0;
+		} else {
+			binder_enqueue_work_ilocked(
+					w, &proc->todo);
+			binder_wakeup_proc_ilocked(proc);
+		}
+		binder_node_inner_unlock(buf_node);
+	}
+	trace_binder_transaction_buffer_release(buffer);
+	binder_transaction_buffer_release(proc, buffer, failed_at);
+	binder_alloc_free_buf(&proc->alloc, buffer);
+}
+
 static int binder_thread_write(struct binder_proc *proc,
 			struct binder_thread *thread,
 			binder_uintptr_t binder_buffer, size_t size,
@@ -3543,32 +3631,7 @@ static int binder_thread_write(struct binder_proc *proc,
 				     buffer->debug_id,
 				     buffer->transaction ? "active" : "finished");
 
-			if (buffer->transaction) {
-				buffer->transaction->buffer = NULL;
-				buffer->transaction = NULL;
-			}
-			if (buffer->async_transaction && buffer->target_node) {
-				struct binder_node *buf_node;
-				struct binder_work *w;
-
-				buf_node = buffer->target_node;
-				binder_node_inner_lock(buf_node);
-				BUG_ON(!buf_node->has_async_transaction);
-				BUG_ON(buf_node->proc != proc);
-				w = binder_dequeue_work_head_ilocked(
-						&buf_node->async_todo);
-				if (!w) {
-					buf_node->has_async_transaction = 0;
-				} else {
-					binder_enqueue_work_ilocked(
-							w, &proc->todo);
-					binder_wakeup_proc_ilocked(proc);
-				}
-				binder_node_inner_unlock(buf_node);
-			}
-			trace_binder_transaction_buffer_release(buffer);
-			binder_transaction_buffer_release(proc, buffer, NULL);
-			binder_alloc_free_buf(&proc->alloc, buffer);
+			binder_free_received_buffer(proc, buffer, NULL);
 			break;
 		}
 
@@ -3945,7 +4008,9 @@ retry:
 
 	while (1) {
 		uint32_t cmd;
-		struct binder_transaction_data tr;
+		struct binder_transaction_data_secctx tr;
+		struct binder_transaction_data *trd = &tr.transaction_data;
+		size_t trsize = sizeof(*trd);
 		struct binder_work *w = NULL;
 		struct list_head *list = NULL;
 		struct binder_transaction *t = NULL;
@@ -3966,7 +4031,11 @@ retry:
 			break;
 		}
 
-		if (end - ptr < sizeof(tr) + 4) {
+		w = list_first_entry(list, struct binder_work, entry);
+		if (w->type == BINDER_WORK_TRANSACTION &&
+		    container_of(w, struct binder_transaction, work)->security_ctx)
+			trsize = sizeof(tr);
+		if (end - ptr < sizeof(uint32_t) + trsize) {
 			binder_inner_proc_unlock(proc);
 			break;
 		}
@@ -4142,53 +4211,68 @@ retry:
 			struct binder_node *target_node = t->buffer->target_node;
 			struct binder_priority node_prio;
 
-			tr.target.ptr = target_node->ptr;
-			tr.cookie =  target_node->cookie;
+			trd->target.ptr = target_node->ptr;
+			trd->cookie =  target_node->cookie;
 			node_prio.sched_policy = target_node->sched_policy;
 			node_prio.prio = target_node->min_priority;
 			binder_transaction_priority(current, t, node_prio,
 						    target_node->inherit_rt);
 			cmd = BR_TRANSACTION;
 		} else {
-			tr.target.ptr = 0;
-			tr.cookie = 0;
+			trd->target.ptr = 0;
+			trd->cookie = 0;
 			cmd = BR_REPLY;
 		}
-		tr.code = t->code;
-		tr.flags = t->flags;
-		tr.sender_euid = from_kuid(current_user_ns(), t->sender_euid);
+		trd->code = t->code;
+		trd->flags = t->flags;
+		trd->sender_euid = from_kuid(current_user_ns(), t->sender_euid);
 
 		t_from = binder_get_txn_from(t);
 		if (t_from) {
 			struct task_struct *sender = t_from->proc->tsk;
 
-			tr.sender_pid = task_tgid_nr_ns(sender,
+			trd->sender_pid = task_tgid_nr_ns(sender,
 							task_active_pid_ns(current));
 		} else {
-			tr.sender_pid = 0;
+			trd->sender_pid = 0;
 		}
 
-		tr.data_size = t->buffer->data_size;
-		tr.offsets_size = t->buffer->offsets_size;
-		tr.data.ptr.buffer = (binder_uintptr_t)
+		trd->data_size = t->buffer->data_size;
+		trd->offsets_size = t->buffer->offsets_size;
+		trd->data.ptr.buffer = (binder_uintptr_t)
 			((uintptr_t)t->buffer->data +
 			binder_alloc_get_user_buffer_offset(&proc->alloc));
-		tr.data.ptr.offsets = tr.data.ptr.buffer +
+		trd->data.ptr.offsets = trd->data.ptr.buffer +
 					ALIGN(t->buffer->data_size,
 					    sizeof(void *));
 
-		if (put_user(cmd, (uint32_t __user *)ptr)) {
-			if (t_from)
-				binder_thread_dec_tmpref(t_from);
-			return -EFAULT;
+		if (t->security_ctx) {
+			tr.secctx = t->security_ctx;
+			cmd = BR_TRANSACTION_SEC_CTX;
 		}
-		ptr += sizeof(uint32_t);
-		if (copy_to_user(ptr, &tr, sizeof(tr))) {
+		if (put_user(cmd, (uint32_t __user *)ptr) ||
+		    copy_to_user(ptr + sizeof(uint32_t), &tr, trsize)) {
 			if (t_from)
 				binder_thread_dec_tmpref(t_from);
+			if (cmd == BR_TRANSACTION_SEC_CTX) {
+				struct binder_buffer *buffer = t->buffer;
+				binder_size_t *offsets_end = (void *)(buffer->data +
+					ALIGN(buffer->data_size, sizeof(void *)) +
+					buffer->offsets_size);
+
+				/* Failed delivery: no BC_FREE_BUFFER will follow. */
+				if (t->set_priority_called)
+					binder_restore_priority(current, t->saved_priority);
+				binder_free_received_buffer(proc, buffer, offsets_end);
+				if (t->flags & TF_ONE_WAY)
+					binder_free_transaction(t);
+				else
+					binder_send_failed_reply(t, BR_FAILED_REPLY);
+			}
 			return -EFAULT;
 		}
-		ptr += sizeof(tr);
+		ptr += sizeof(uint32_t);
+		ptr += trsize;
 
 		trace_binder_transaction_received(t);
 		binder_stat_br(proc, thread, cmd);
@@ -4200,12 +4284,12 @@ retry:
 			     t->debug_id, t_from ? t_from->proc->pid : 0,
 			     t_from ? t_from->pid : 0, cmd,
 			     t->buffer->data_size, t->buffer->offsets_size,
-			     (u64)tr.data.ptr.buffer, (u64)tr.data.ptr.offsets);
+			     (u64)trd->data.ptr.buffer, (u64)trd->data.ptr.offsets);
 
 		if (t_from)
 			binder_thread_dec_tmpref(t_from);
 		t->buffer->allow_user_free = 1;
-		if (cmd == BR_TRANSACTION && !(t->flags & TF_ONE_WAY)) {
+		if (cmd != BR_REPLY && !(t->flags & TF_ONE_WAY)) {
 			binder_inner_proc_lock(thread->proc);
 			t->to_parent = thread->transaction_stack;
 			t->to_thread = thread;
@@ -4365,6 +4449,7 @@ static void binder_free_proc(struct binder_proc *proc)
 	BUG_ON(!list_empty(&proc->todo));
 	BUG_ON(!list_empty(&proc->delivered_death));
 	binder_alloc_deferred_release(&proc->alloc);
+	put_cred(proc->cred);
 	put_task_struct(proc->tsk);
 	binder_stats_deleted(BINDER_STAT_PROC);
 	kfree(proc);
@@ -4545,7 +4630,8 @@ out:
 	return ret;
 }
 
-static int binder_ioctl_set_ctx_mgr(struct file *filp)
+static int binder_ioctl_set_ctx_mgr(struct file *filp,
+				    struct flat_binder_object *fbo)
 {
 	int ret = 0;
 	struct binder_proc *proc = filp->private_data;
@@ -4559,7 +4645,7 @@ static int binder_ioctl_set_ctx_mgr(struct file *filp)
 		ret = -EBUSY;
 		goto out;
 	}
-	ret = security_binder_set_context_mgr(proc->tsk);
+	ret = security_binder_set_context_mgr(proc->cred);
 	if (ret < 0)
 		goto out;
 	if (uid_valid(context->binder_context_mgr_uid)) {
@@ -4574,7 +4660,7 @@ static int binder_ioctl_set_ctx_mgr(struct file *filp)
 	} else {
 		context->binder_context_mgr_uid = curr_euid;
 	}
-	new_node = binder_new_node(proc, NULL);
+	new_node = binder_new_node(proc, fbo);
 	if (!new_node) {
 		ret = -ENOMEM;
 		goto out;
@@ -4658,8 +4744,20 @@ static long binder_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
 		binder_inner_proc_unlock(proc);
 		break;
 	}
+	case BINDER_SET_CONTEXT_MGR_EXT: {
+		struct flat_binder_object fbo;
+
+		if (copy_from_user(&fbo, ubuf, sizeof(fbo))) {
+			ret = -EFAULT;
+			goto err;
+		}
+		ret = binder_ioctl_set_ctx_mgr(filp, &fbo);
+		if (ret)
+			goto err;
+		break;
+	}
 	case BINDER_SET_CONTEXT_MGR:
-		ret = binder_ioctl_set_ctx_mgr(filp);
+		ret = binder_ioctl_set_ctx_mgr(filp, NULL);
 		if (ret)
 			goto err;
 		break;
@@ -4806,6 +4904,7 @@ static int binder_open(struct inode *nodp, struct file *filp)
 	spin_lock_init(&proc->outer_lock);
 	get_task_struct(current->group_leader);
 	proc->tsk = current->group_leader;
+	proc->cred = get_cred(filp->f_cred);
 	INIT_LIST_HEAD(&proc->todo);
 	if (binder_supported_policy(current->policy)) {
 		proc->default_priority.sched_policy = current->policy;
diff --git a/include/linux/lsm_hooks.h b/include/linux/lsm_hooks.h
index 558adfa..dff80da 100644
--- a/include/linux/lsm_hooks.h
+++ b/include/linux/lsm_hooks.h
@@ -1332,13 +1332,13 @@
  */
 
 union security_list_options {
-	int (*binder_set_context_mgr)(struct task_struct *mgr);
-	int (*binder_transaction)(struct task_struct *from,
-					struct task_struct *to);
-	int (*binder_transfer_binder)(struct task_struct *from,
-					struct task_struct *to);
-	int (*binder_transfer_file)(struct task_struct *from,
-					struct task_struct *to,
+	int (*binder_set_context_mgr)(const struct cred *mgr);
+	int (*binder_transaction)(const struct cred *from,
+					const struct cred *to);
+	int (*binder_transfer_binder)(const struct cred *from,
+					const struct cred *to);
+	int (*binder_transfer_file)(const struct cred *from,
+					const struct cred *to,
 					struct file *file);
 
 	int (*ptrace_access_check)(struct task_struct *child,
@@ -1496,6 +1496,7 @@ union security_list_options {
 	int (*task_setpgid)(struct task_struct *p, pid_t pgid);
 	int (*task_getpgid)(struct task_struct *p);
 	int (*task_getsid)(struct task_struct *p);
+	void (*cred_getsecid)(const struct cred *cred, u32 *secid);
 	void (*task_getsecid)(struct task_struct *p, u32 *secid);
 	int (*task_setnice)(struct task_struct *p, int nice);
 	int (*task_setioprio)(struct task_struct *p, int ioprio);
@@ -1759,6 +1760,7 @@ struct security_hook_heads {
 	struct list_head task_setpgid;
 	struct list_head task_getpgid;
 	struct list_head task_getsid;
+	struct list_head cred_getsecid;
 	struct list_head task_getsecid;
 	struct list_head task_setnice;
 	struct list_head task_setioprio;
diff --git a/include/linux/security.h b/include/linux/security.h
index aaf6046..8a4af5a 100644
--- a/include/linux/security.h
+++ b/include/linux/security.h
@@ -216,13 +216,13 @@ static inline void security_free_mnt_opts(struct security_mnt_opts *opts)
 extern int security_init(void);
 
 /* Security operations */
-int security_binder_set_context_mgr(struct task_struct *mgr);
-int security_binder_transaction(struct task_struct *from,
-				struct task_struct *to);
-int security_binder_transfer_binder(struct task_struct *from,
-				    struct task_struct *to);
-int security_binder_transfer_file(struct task_struct *from,
-				  struct task_struct *to, struct file *file);
+int security_binder_set_context_mgr(const struct cred *mgr);
+int security_binder_transaction(const struct cred *from,
+				const struct cred *to);
+int security_binder_transfer_binder(const struct cred *from,
+				    const struct cred *to);
+int security_binder_transfer_file(const struct cred *from,
+				  const struct cred *to, struct file *file);
 int security_ptrace_access_check(struct task_struct *child, unsigned int mode);
 int security_ptrace_traceme(struct task_struct *parent);
 int security_capget(struct task_struct *target,
@@ -354,6 +354,7 @@ int security_task_setpgid(struct task_struct *p, pid_t pgid);
 int security_task_getpgid(struct task_struct *p);
 int security_task_getsid(struct task_struct *p);
 void security_task_getsecid(struct task_struct *p, u32 *secid);
+void security_cred_getsecid(const struct cred *cred, u32 *secid);
 int security_task_setnice(struct task_struct *p, int nice);
 int security_task_setioprio(struct task_struct *p, int ioprio);
 int security_task_getioprio(struct task_struct *p);
@@ -426,25 +427,25 @@ static inline int security_init(void)
 	return 0;
 }
 
-static inline int security_binder_set_context_mgr(struct task_struct *mgr)
+static inline int security_binder_set_context_mgr(const struct cred *mgr)
 {
 	return 0;
 }
 
-static inline int security_binder_transaction(struct task_struct *from,
-					      struct task_struct *to)
+static inline int security_binder_transaction(const struct cred *from,
+					      const struct cred *to)
 {
 	return 0;
 }
 
-static inline int security_binder_transfer_binder(struct task_struct *from,
-						  struct task_struct *to)
+static inline int security_binder_transfer_binder(const struct cred *from,
+						  const struct cred *to)
 {
 	return 0;
 }
 
-static inline int security_binder_transfer_file(struct task_struct *from,
-						struct task_struct *to,
+static inline int security_binder_transfer_file(const struct cred *from,
+						const struct cred *to,
 						struct file *file)
 {
 	return 0;
@@ -963,6 +964,11 @@ static inline int security_task_getsid(struct task_struct *p)
 	return 0;
 }
 
+static inline void security_cred_getsecid(const struct cred *cred, u32 *secid)
+{
+	*secid = 0;
+}
+
 static inline void security_task_getsecid(struct task_struct *p, u32 *secid)
 {
 	*secid = 0;
diff --git a/include/uapi/linux/android/binder.h b/include/uapi/linux/android/binder.h
index 5539933..24137b5 100644
--- a/include/uapi/linux/android/binder.h
+++ b/include/uapi/linux/android/binder.h
@@ -50,6 +50,8 @@ enum flat_binder_object_shifts {
  * enum flat_binder_object_flags - flags for use in flat_binder_object.flags
  */
 enum flat_binder_object_flags {
+	/* Deliver the sender security context with incoming transactions. */
+	FLAT_BINDER_FLAG_TXN_SECURITY_CTX = 0x1000,
 	/**
 	 * @FLAT_BINDER_FLAG_PRIORITY_MASK: bit-mask for min scheduler priority
 	 *
@@ -250,6 +252,7 @@ struct binder_node_debug_info {
 #define BINDER_SET_IDLE_TIMEOUT		_IOW('b', 3, __s64)
 #define BINDER_SET_MAX_THREADS		_IOW('b', 5, __u32)
 #define BINDER_SET_IDLE_PRIORITY	_IOW('b', 6, __s32)
+#define BINDER_SET_CONTEXT_MGR_EXT	_IOW('b', 13, struct flat_binder_object)
 #define BINDER_SET_CONTEXT_MGR		_IOW('b', 7, __s32)
 #define BINDER_THREAD_EXIT		_IOW('b', 8, __s32)
 #define BINDER_VERSION			_IOWR('b', 9, struct binder_version)
@@ -312,6 +315,11 @@ struct binder_transaction_data {
 	} data;
 };
 
+struct binder_transaction_data_secctx {
+	struct binder_transaction_data transaction_data;
+	binder_uintptr_t secctx;
+};
+
 struct binder_transaction_data_sg {
 	struct binder_transaction_data transaction_data;
 	binder_size_t buffers_size;
@@ -347,6 +355,7 @@ enum binder_driver_return_protocol {
 	BR_OK = _IO('r', 1),
 	/* No parameters! */
 
+	BR_TRANSACTION_SEC_CTX = _IOR('r', 2, struct binder_transaction_data_secctx),
 	BR_TRANSACTION = _IOR('r', 2, struct binder_transaction_data),
 	BR_REPLY = _IOR('r', 3, struct binder_transaction_data),
 	/*
diff --git a/security/security.c b/security/security.c
index 1ba5274..dfdf078 100644
--- a/security/security.c
+++ b/security/security.c
@@ -131,25 +131,25 @@ int __init security_module_enable(const char *module)
 
 /* Security operations */
 
-int security_binder_set_context_mgr(struct task_struct *mgr)
+int security_binder_set_context_mgr(const struct cred *mgr)
 {
 	return call_int_hook(binder_set_context_mgr, 0, mgr);
 }
 
-int security_binder_transaction(struct task_struct *from,
-				struct task_struct *to)
+int security_binder_transaction(const struct cred *from,
+				const struct cred *to)
 {
 	return call_int_hook(binder_transaction, 0, from, to);
 }
 
-int security_binder_transfer_binder(struct task_struct *from,
-				    struct task_struct *to)
+int security_binder_transfer_binder(const struct cred *from,
+				    const struct cred *to)
 {
 	return call_int_hook(binder_transfer_binder, 0, from, to);
 }
 
-int security_binder_transfer_file(struct task_struct *from,
-				  struct task_struct *to, struct file *file)
+int security_binder_transfer_file(const struct cred *from,
+				  const struct cred *to, struct file *file)
 {
 	return call_int_hook(binder_transfer_file, 0, from, to, file);
 }
@@ -977,6 +977,12 @@ int security_task_getsid(struct task_struct *p)
 	return call_int_hook(task_getsid, 0, p);
 }
 
+void security_cred_getsecid(const struct cred *cred, u32 *secid)
+{
+	*secid = 0;
+	call_void_hook(cred_getsecid, cred, secid);
+}
+
 void security_task_getsecid(struct task_struct *p, u32 *secid)
 {
 	*secid = 0;
@@ -1754,6 +1760,7 @@ struct security_hook_heads security_hook_heads = {
 	.task_setpgid =	LIST_HEAD_INIT(security_hook_heads.task_setpgid),
 	.task_getpgid =	LIST_HEAD_INIT(security_hook_heads.task_getpgid),
 	.task_getsid =	LIST_HEAD_INIT(security_hook_heads.task_getsid),
+	.cred_getsecid = LIST_HEAD_INIT(security_hook_heads.cred_getsecid),
 	.task_getsecid =
 		LIST_HEAD_INIT(security_hook_heads.task_getsecid),
 	.task_setnice =	LIST_HEAD_INIT(security_hook_heads.task_setnice),
diff --git a/security/selinux/hooks.c b/security/selinux/hooks.c
index c332df5..b3a63e3 100644
--- a/security/selinux/hooks.c
+++ b/security/selinux/hooks.c
@@ -2197,10 +2197,10 @@ static inline u32 open_file_to_av(struct file *file)
 
 /* Hook functions begin here. */
 
-static int selinux_binder_set_context_mgr(struct task_struct *mgr)
+static int selinux_binder_set_context_mgr(const struct cred *mgr)
 {
 	u32 mysid = current_sid();
-	u32 mgrsid = task_sid(mgr);
+	u32 mgrsid = cred_sid(mgr);
 #ifdef CONFIG_RKP_KDP
 	int rc;
 
@@ -2212,12 +2212,12 @@ static int selinux_binder_set_context_mgr(struct task_struct *mgr)
 			    BINDER__SET_CONTEXT_MGR, NULL);
 }
 
-static int selinux_binder_transaction(struct task_struct *from,
-				      struct task_struct *to)
+static int selinux_binder_transaction(const struct cred *from,
+				      const struct cred *to)
 {
 	u32 mysid = current_sid();
-	u32 fromsid = task_sid(from);
-	u32 tosid = task_sid(to);
+	u32 fromsid = cred_sid(from);
+	u32 tosid = cred_sid(to);
 	int rc;
 #ifdef CONFIG_RKP_KDP
 	if ((rc = security_integrity_current()))
@@ -2234,11 +2234,11 @@ static int selinux_binder_transaction(struct task_struct *from,
 			    NULL);
 }
 
-static int selinux_binder_transfer_binder(struct task_struct *from,
-					  struct task_struct *to)
+static int selinux_binder_transfer_binder(const struct cred *from,
+					  const struct cred *to)
 {
-	u32 fromsid = task_sid(from);
-	u32 tosid = task_sid(to);
+	u32 fromsid = cred_sid(from);
+	u32 tosid = cred_sid(to);
 #ifdef CONFIG_RKP_KDP
 	int rc;
 
@@ -2249,11 +2249,11 @@ static int selinux_binder_transfer_binder(struct task_struct *from,
 			    NULL);
 }
 
-static int selinux_binder_transfer_file(struct task_struct *from,
-					struct task_struct *to,
+static int selinux_binder_transfer_file(const struct cred *from,
+					const struct cred *to,
 					struct file *file)
 {
-	u32 sid = task_sid(to);
+	u32 sid = cred_sid(to);
 	struct file_security_struct *fsec = file->f_security;
 	struct dentry *dentry = file->f_path.dentry;
 	struct inode_security_struct *isec;
@@ -4400,6 +4400,11 @@ static int selinux_task_getsid(struct task_struct *p)
 	return current_has_perm(p, PROCESS__GETSESSION);
 }
 
+static void selinux_cred_getsecid(const struct cred *cred, u32 *secid)
+{
+	*secid = cred_sid(cred);
+}
+
 static void selinux_task_getsecid(struct task_struct *p, u32 *secid)
 {
 #ifdef CONFIG_RKP_KDP
@@ -7169,6 +7174,7 @@ static struct security_hook_list selinux_hooks[] = {
 	LSM_HOOK_INIT(task_setpgid, selinux_task_setpgid),
 	LSM_HOOK_INIT(task_getpgid, selinux_task_getpgid),
 	LSM_HOOK_INIT(task_getsid, selinux_task_getsid),
+	LSM_HOOK_INIT(cred_getsecid, selinux_cred_getsecid),
 	LSM_HOOK_INIT(task_getsecid, selinux_task_getsecid),
 	LSM_HOOK_INIT(task_setnice, selinux_task_setnice),
 	LSM_HOOK_INIT(task_setioprio, selinux_task_setioprio),
BINDER_REVIEW_V2
    sha256sum "$out/binder-security-context.patch" > "$out/binder-patch.sha256"
    git apply --check --verbose "$out/binder-security-context.patch" 2>&1 | tee "$out/binder-patch-check.log"
    git apply "$out/binder-security-context.patch"
    # Diagnostic-only changes to the extracted QEMU copy.
    python3 - <<'BINDER_TRACE'
from pathlib import Path
p = Path("drivers/android/binder.c")
s = p.read_text()
def add(anchor, suffix):
    global s
    if s.count(anchor) != 1:
        raise SystemExit(f"expected one trace anchor: {anchor!r}")
    s = s.replace(anchor, anchor + suffix)
add('\t\tret = binder_ioctl_set_ctx_mgr(filp, &fbo);\n', '''
		pr_info_ratelimited("binder context-manager register device=%s pid=%d secctx_requested=%d ret=%d\\n",
				    proc->context->name, proc->pid,
				    !!(fbo.flags & FLAT_BINDER_FLAG_TXN_SECURITY_CTX), ret);
''')
add('\t\ttrace_binder_transaction_received(t);\n', '''
		if (cmd == BR_TRANSACTION_SEC_CTX || cmd == BR_REPLY)
			pr_info_ratelimited("binder context-manager delivery device=%s pid=%d txn=%d command=%s sync=%d\\n",
					    proc->context->name, proc->pid, t->debug_id,
					    cmd == BR_REPLY ? "reply" : "secctx",
					    !(t->flags & TF_ONE_WAY));
''')
add('\ttrace_binder_transaction(reply, t, target_node);\n', '''
	if (reply && in_reply_to->security_ctx)
		pr_info_ratelimited("binder context-manager reply attempt device=%s pid=%d request=%d reply=%d\\n",
				    proc->context->name, proc->pid,
				    in_reply_to->debug_id, t->debug_id);
''')
p.write_text(s)
BINDER_TRACE
    stage=config
fi
bash "$repo/ci/samsung-virt/configure.sh" "$PWD" 2>&1 | tee "$out/configure.log"
cp .config "$out/config.final"
if [[ ${DRM_BUFFER_GATE:-0} == 1 ]]; then
    mkdir -p "$out/drm-uapi/drm"
    cp include/uapi/drm/{drm.h,drm_mode.h,drm_fourcc.h} "$out/drm-uapi/drm/"
    (cd "$out/drm-uapi" && sha256sum drm/*.h > SHA256SUMS)
fi
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    grep -E '^(CONFIG_(DM_DEFAULT_KEY|BLK_DEV_DM|DM_CRYPT|BLK_INLINE_ENCRYPTION|BLK_INLINE_ENCRYPTION_FALLBACK|FS_ENCRYPTION|EXT4_ENCRYPTION)=|# CONFIG_(DM_DEFAULT_KEY|BLK_DEV_DM|DM_CRYPT|BLK_INLINE_ENCRYPTION|BLK_INLINE_ENCRYPTION_FALLBACK|FS_ENCRYPTION|EXT4_ENCRYPTION) is not set)' .config > "$out/dm-default-key-compiled-config.txt" || true
fi
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]] && grep -Eq '^CONFIG_RKP(_KDP)?=y$' .config; then
    echo 'Binder review v2 is restricted to the non-RKP QEMU configuration.' >&2
    exit 1
fi
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    while IFS= read -r setting; do
        grep -Fxq "$setting" .config || { echo "Unresolved integration setting: $setting" >&2; exit 1; }
    done < "$ANDROID_INIT_FRAGMENT"
fi
stage=build
make -k -j"$(nproc)" Image 2>&1 | tee "$out/build.log"
cp arch/arm64/boot/Image System.map "$out/"
if [[ ${DRM_BUFFER_GATE:-0} == 1 ]]; then
    grep -E ' [tT] (drm_core_init|virtio_gpu_probe)$' System.map > "$out/drm-symbols.txt"
    grep -q ' drm_core_init$' "$out/drm-symbols.txt"
    grep -q ' virtio_gpu_probe$' "$out/drm-symbols.txt"
fi
test "$(od -An -j56 -N4 -tx1 "$out/Image" | tr -d '[:space:]')" = 41524d64
for symbol in binder_init selinux_init pl011_console_write gic_init_bases psci_dt_init arch_timer_of_init; do
    grep -w "$symbol" "$out/System.map" || echo "Symbol absent: $symbol"
done | tee "$out/symbols.txt"
grep -qw binder_init "$out/System.map"
grep -qw selinux_init "$out/System.map"
(cd "$out" && sha256sum Image System.map config.final > SHA256SUMS)
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    stage=kernel_ready
    exit 0
fi
stage=initramfs
mkdir -p "$work/uapi/linux/android"
cp include/uapi/linux/android/binder.h "$work/uapi/linux/android/"
aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -static -O2 \
    -I "$work/uapi" "$repo/ci/samsung-virt/probe.c" -o "$work/init"
checkpolicy -c 30 -o "$work/test.policy" "$out/test.conf" 2>&1 | tee "$out/policy-build.log"
cc -O2 usr/gen_init_cpio.c -o "$work/gen_init_cpio"
cat > "$work/initramfs.list" <<LIST
dir /dev 755 0 0
nod /dev/console 600 0 0 c 5 1
dir /sys 755 0 0
file /init $work/init 755 0 0
file /test.policy $work/test.policy 644 0 0
LIST
"$work/gen_init_cpio" "$work/initramfs.list" > "$out/initramfs.cpio"
cp "$work/test.policy" "$out/"
(cd "$out" && sha256sum Image System.map config.final initramfs.cpio test.policy > SHA256SUMS)
stage=qemu
# A PASS marker must be present even if QEMU is terminated by the timeout.
rc=0
timeout 100 qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a57 \
    -accel tcg -smp 2 -m 1024 -nodefaults -display none -monitor none \
    -serial stdio -no-reboot -kernel "$out/Image" -initrd "$out/initramfs.cpio" \
    -append 'console=ttyAMA0 rdinit=/init rootfstype=ramfs ignore_loglevel audit=1 panic=1' > "$out/serial.log" 2>&1 || rc=$?
printf '%d\n' "$rc" > "$out/qemu-exit.txt"
cat "$out/serial.log"
for marker in 'PASS guest init started' 'PASS /dev/binder protocol=' \
    'PASS /dev/hwbinder protocol=' 'PASS /dev/vndbinder protocol=' \
    'PASS Binder transaction client=' 'PASS SELinux v30 load enforcing allow and denial' \
    'PASS all guest checks'; do
    grep -Fq "$marker" "$out/serial.log" || { echo "Missing: $marker" >&2; exit 1; }
done
stage=complete

if [[ -n ${REFERENCE_POLICY:-} ]]; then
    stage=android_policy
    cp "$REFERENCE_POLICY" "$out/android-policy-v30.bin"
    (cd "$out" && echo 'cefa481b0011472ba4ba9447bb66fe1663716992eda114fb7162408598fb91b5  android-policy-v30.bin' | sha256sum -c -)
    aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -static -O2 \
        -DREFERENCE_POLICY -I "$work/uapi" "$repo/ci/samsung-virt/probe.c" -o "$work/init"
    cp "$out/android-policy-v30.bin" "$work/test.policy"
    "$work/gen_init_cpio" "$work/initramfs.list" > "$out/android-policy-initramfs.cpio"
    qemu_rc=0
    timeout 45 qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a57 \
        -accel tcg -smp 2 -m 1024 -nodefaults -display none -monitor none \
        -serial stdio -no-reboot -kernel "$out/Image" -initrd "$out/android-policy-initramfs.cpio" \
        -append 'console=ttyAMA0 rdinit=/init rootfstype=ramfs ignore_loglevel audit=1 panic=1' \
        > "$out/android-policy-serial.log" 2>&1 || qemu_rc=$?
    printf '%s\n' "$qemu_rc" > "$out/android-policy-qemu-exit.txt"
    tail -100 "$out/android-policy-serial.log"
    grep -Fq 'virt-policy: load result=520276 bytes=520276 enforcing=1' "$out/android-policy-serial.log"
    grep -Fq 'policy loaded' "$out/android-policy-serial.log"
    (cd "$out" && sha256sum android-policy-v30.bin android-policy-initramfs.cpio >> SHA256SUMS)
    stage=complete
fi
