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
# Generic CPU hotplug has a Samsung header include but uses none of its declarations.
# Remove that dependency only in this disposable non-Exynos source tree.
grep -Fxq '#include <soc/samsung/exynos-powermode.h>' kernel/cpu.c
sed -i '\|^#include <soc/samsung/exynos-powermode.h>$|d' kernel/cpu.c
# No graphics are needed for this serial-only guest. Samsung's unconditional
# GPU entry otherwise expects arm/built-in.o even with Mali deselected.
grep -Eq '^obj-y[[:space:]]*\+=[[:space:]]*gpu/[[:space:]]*$' drivers/Makefile
sed -i -E '/^obj-y[[:space:]]*\+=[[:space:]]*gpu\/[[:space:]]*$/d' drivers/Makefile
echo "Excluded the GPU subtree from this headless virt build."
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
    # Trial only: verify the complete patch before changing the source tree.
    cat > "$out/binder-security-context.patch" <<'BINDER_UPSTREAM_PATCH'
diff --git a/drivers/android/binder.c b/drivers/android/binder.c
--- a/drivers/android/binder.c
+++ b/drivers/android/binder.c
@@ -329,6 +329,8 @@ struct binder_error {
  *                        (invariant after initialized)
  * @min_priority:         minimum scheduling priority
  *                        (invariant after initialized)
+ * @txn_security_ctx:     require sender's security context
+ *                        (invariant after initialized)
  * @async_todo:           list of async work items
  *                        (protected by @proc->inner_lock)
  *
@@ -365,6 +367,7 @@ struct binder_node {
 		 * invariant after initialization
 		 */
 		u8 accept_fds:1;
+		u8 txn_security_ctx:1;
 		u8 min_priority;
 	};
 	bool has_async_transaction;
@@ -615,6 +618,7 @@ struct binder_transaction {
 	long	saved_priority;
 	kuid_t	sender_euid;
 	struct list_head fd_fixups;
+	binder_uintptr_t security_ctx;
 	/**
 	 * @lock:  protects @from, @to_proc, and @to_thread
 	 *
@@ -1152,6 +1156,7 @@ static struct binder_node *binder_init_node_ilocked(
 	node->work.type = BINDER_WORK_NODE;
 	node->min_priority = flags & FLAT_BINDER_FLAG_PRIORITY_MASK;
 	node->accept_fds = !!(flags & FLAT_BINDER_FLAG_ACCEPTS_FDS);
+	node->txn_security_ctx = !!(flags & FLAT_BINDER_FLAG_TXN_SECURITY_CTX);
 	spin_lock_init(&node->lock);
 	INIT_LIST_HEAD(&node->work.entry);
 	INIT_LIST_HEAD(&node->async_todo);
@@ -2778,6 +2783,8 @@ static void binder_transaction(struct binder_proc *proc,
 	binder_size_t last_fixup_min_off = 0;
 	struct binder_context *context = proc->context;
 	int t_debug_id = atomic_inc_return(&binder_last_id);
+	char *secctx = NULL;
+	u32 secctx_sz = 0;
 
 	e = binder_transaction_log_add(&binder_transaction_log);
 	e->debug_id = t_debug_id;
@@ -3020,6 +3027,20 @@ static void binder_transaction(struct binder_proc *proc,
 	t->flags = tr->flags;
 	t->priority = task_nice(current);
 
+	if (target_node && target_node->txn_security_ctx) {
+		u32 secid;
+
+		security_task_getsecid(proc->tsk, &secid);
+		ret = security_secid_to_secctx(secid, &secctx, &secctx_sz);
+		if (ret) {
+			return_error = BR_FAILED_REPLY;
+			return_error_param = ret;
+			return_error_line = __LINE__;
+			goto err_get_secctx_failed;
+		}
+		extra_buffers_size += ALIGN(secctx_sz, sizeof(u64));
+	}
+
 	trace_binder_transaction(reply, t, target_node);
 
 	t->buffer = binder_alloc_new_buf(&target_proc->alloc, tr->data_size,
@@ -3036,6 +3057,19 @@ static void binder_transaction(struct binder_proc *proc,
 		t->buffer = NULL;
 		goto err_binder_alloc_buf_failed;
 	}
+	if (secctx) {
+		size_t buf_offset = ALIGN(tr->data_size, sizeof(void *)) +
+				    ALIGN(tr->offsets_size, sizeof(void *)) +
+				    ALIGN(extra_buffers_size, sizeof(void *)) -
+				    ALIGN(secctx_sz, sizeof(u64));
+		char *kptr = t->buffer->data + buf_offset;
+
+		t->security_ctx = (uintptr_t)kptr +
+		    binder_alloc_get_user_buffer_offset(&target_proc->alloc);
+		memcpy(kptr, secctx, secctx_sz);
+		security_release_secctx(secctx, secctx_sz);
+		secctx = NULL;
+	}
 	t->buffer->debug_id = t->debug_id;
 	t->buffer->transaction = t;
 	t->buffer->target_node = target_node;
@@ -3305,6 +3339,9 @@ static void binder_transaction(struct binder_proc *proc,
 	t->buffer->transaction = NULL;
 	binder_alloc_free_buf(&target_proc->alloc, t->buffer);
 err_binder_alloc_buf_failed:
+	if (secctx)
+		security_release_secctx(secctx, secctx_sz);
+err_get_secctx_failed:
 	kfree(tcomplete);
 	binder_stats_deleted(BINDER_STAT_TRANSACTION_COMPLETE);
 err_alloc_tcomplete_failed:
@@ -4036,11 +4073,13 @@ static int binder_thread_read(struct binder_proc *proc,
 
 	while (1) {
 		uint32_t cmd;
-		struct binder_transaction_data tr;
+		struct binder_transaction_data_secctx tr;
+		struct binder_transaction_data *trd = &tr.transaction_data;
 		struct binder_work *w = NULL;
 		struct list_head *list = NULL;
 		struct binder_transaction *t = NULL;
 		struct binder_thread *t_from;
+		size_t trsize = sizeof(*trd);
 
 		binder_inner_proc_lock(proc);
 		if (!binder_worklist_empty_ilocked(&thread->todo))
@@ -4240,8 +4279,8 @@ static int binder_thread_read(struct binder_proc *proc,
 		if (t->buffer->target_node) {
 			struct binder_node *target_node = t->buffer->target_node;
 
-			tr.target.ptr = target_node->ptr;
-			tr.cookie =  target_node->cookie;
+			trd->target.ptr = target_node->ptr;
+			trd->cookie =  target_node->cookie;
 			t->saved_priority = task_nice(current);
 			if (t->priority < target_node->min_priority &&
 			    !(t->flags & TF_ONE_WAY))
@@ -4251,22 +4290,23 @@ static int binder_thread_read(struct binder_proc *proc,
 				binder_set_nice(target_node->min_priority);
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
-							task_active_pid_ns(current));
+			trd->sender_pid =
+				task_tgid_nr_ns(sender,
+						task_active_pid_ns(current));
 		} else {
-			tr.sender_pid = 0;
+			trd->sender_pid = 0;
 		}
 
 		ret = binder_apply_fd_fixups(t);
@@ -4297,15 +4337,20 @@ static int binder_thread_read(struct binder_proc *proc,
 			}
 			continue;
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
 
+		tr.secctx = t->security_ctx;
+		if (t->security_ctx) {
+			cmd = BR_TRANSACTION_SEC_CTX;
+			trsize = sizeof(tr);
+		}
 		if (put_user(cmd, (uint32_t __user *)ptr)) {
 			if (t_from)
 				binder_thread_dec_tmpref(t_from);
@@ -4316,7 +4361,7 @@ static int binder_thread_read(struct binder_proc *proc,
 			return -EFAULT;
 		}
 		ptr += sizeof(uint32_t);
-		if (copy_to_user(ptr, &tr, sizeof(tr))) {
+		if (copy_to_user(ptr, &tr, trsize)) {
 			if (t_from)
 				binder_thread_dec_tmpref(t_from);
 
@@ -4325,24 +4370,26 @@ static int binder_thread_read(struct binder_proc *proc,
 
 			return -EFAULT;
 		}
-		ptr += sizeof(tr);
+		ptr += trsize;
 
 		trace_binder_transaction_received(t);
 		binder_stat_br(proc, thread, cmd);
 		binder_debug(BINDER_DEBUG_TRANSACTION,
 			     "%d:%d %s %d %d:%d, cmd %d size %zd-%zd ptr %016llx-%016llx\n",
 			     proc->pid, thread->pid,
 			     (cmd == BR_TRANSACTION) ? "BR_TRANSACTION" :
-			     "BR_REPLY",
+				(cmd == BR_TRANSACTION_SEC_CTX) ?
+				     "BR_TRANSACTION_SEC_CTX" : "BR_REPLY",
 			     t->debug_id, t_from ? t_from->proc->pid : 0,
 			     t_from ? t_from->pid : 0, cmd,
 			     t->buffer->data_size, t->buffer->offsets_size,
-			     (u64)tr.data.ptr.buffer, (u64)tr.data.ptr.offsets);
+			     (u64)trd->data.ptr.buffer,
+			     (u64)trd->data.ptr.offsets);
 
 		if (t_from)
 			binder_thread_dec_tmpref(t_from);
 		t->buffer->allow_user_free = 1;
-		if (cmd == BR_TRANSACTION && !(t->flags & TF_ONE_WAY)) {
+		if (cmd != BR_REPLY && !(t->flags & TF_ONE_WAY)) {
 			binder_inner_proc_lock(thread->proc);
 			t->to_parent = thread->transaction_stack;
 			t->to_thread = thread;
@@ -4690,7 +4737,8 @@ static int binder_ioctl_write_read(struct file *filp,
 	return ret;
 }
 
-static int binder_ioctl_set_ctx_mgr(struct file *filp)
+static int binder_ioctl_set_ctx_mgr(struct file *filp,
+				    struct flat_binder_object *fbo)
 {
 	int ret = 0;
 	struct binder_proc *proc = filp->private_data;
@@ -4719,7 +4767,7 @@ static int binder_ioctl_set_ctx_mgr(struct file *filp)
 	} else {
 		context->binder_context_mgr_uid = curr_euid;
 	}
-	new_node = binder_new_node(proc, NULL);
+	new_node = binder_new_node(proc, fbo);
 	if (!new_node) {
 		ret = -ENOMEM;
 		goto out;
@@ -4842,8 +4890,20 @@ static long binder_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
 		binder_inner_proc_unlock(proc);
 		break;
 	}
+	case BINDER_SET_CONTEXT_MGR_EXT: {
+		struct flat_binder_object fbo;
+
+		if (copy_from_user(&fbo, ubuf, sizeof(fbo))) {
+			ret = -EINVAL;
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
diff --git a/include/uapi/linux/android/binder.h b/include/uapi/linux/android/binder.h
--- a/include/uapi/linux/android/binder.h
+++ b/include/uapi/linux/android/binder.h
@@ -41,6 +41,14 @@ enum {
 enum {
 	FLAT_BINDER_FLAG_PRIORITY_MASK = 0xff,
 	FLAT_BINDER_FLAG_ACCEPTS_FDS = 0x100,
+
+	/**
+	 * @FLAT_BINDER_FLAG_TXN_SECURITY_CTX: request security contexts
+	 *
+	 * Only when set, causes senders to include their security
+	 * context
+	 */
+	FLAT_BINDER_FLAG_TXN_SECURITY_CTX = 0x1000,
 };
 
 #ifdef BINDER_IPC_32BIT
@@ -218,6 +226,7 @@ struct binder_node_info_for_ref {
 #define BINDER_VERSION			_IOWR('b', 9, struct binder_version)
 #define BINDER_GET_NODE_DEBUG_INFO	_IOWR('b', 11, struct binder_node_debug_info)
 #define BINDER_GET_NODE_INFO_FOR_REF	_IOWR('b', 12, struct binder_node_info_for_ref)
+#define BINDER_SET_CONTEXT_MGR_EXT	_IOW('b', 13, struct flat_binder_object)
 
 /*
  * NOTE: Two special error codes you should check for when calling
@@ -276,6 +285,11 @@ struct binder_transaction_data {
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
@@ -311,6 +325,11 @@ enum binder_driver_return_protocol {
 	BR_OK = _IO('r', 1),
 	/* No parameters! */
 
+	BR_TRANSACTION_SEC_CTX = _IOR('r', 2,
+				      struct binder_transaction_data_secctx),
+	/*
+	 * binder_transaction_data_secctx: the received command.
+	 */
 	BR_TRANSACTION = _IOR('r', 2, struct binder_transaction_data),
 	BR_REPLY = _IOR('r', 3, struct binder_transaction_data),
 	/*
BINDER_UPSTREAM_PATCH
    sha256sum "$out/binder-security-context.patch" > "$out/binder-patch.sha256"
    git apply --check --verbose "$out/binder-security-context.patch" 2>&1 | tee "$out/binder-patch-check.log"
    git apply "$out/binder-security-context.patch"
    stage=config
fi
bash "$repo/ci/samsung-virt/configure.sh" "$PWD" 2>&1 | tee "$out/configure.log"
cp .config "$out/config.final"
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    while IFS= read -r setting; do
        grep -Fxq "$setting" .config || { echo "Unresolved integration setting: $setting" >&2; exit 1; }
    done < "$ANDROID_INIT_FRAGMENT"
fi
stage=build
make -k -j"$(nproc)" Image 2>&1 | tee "$out/build.log"
cp arch/arm64/boot/Image System.map "$out/"
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
