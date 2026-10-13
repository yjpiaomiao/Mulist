package io.github.musicmanager.music_manager

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Storage Access Framework bridge.
 *
 * Calls run on a background task queue (they can be made from any Dart
 * isolate through BackgroundIsolateBinaryMessenger). Files are passed to the
 * native core as raw descriptors (detachFd); the Dart side closes them.
 */
class SafStorage(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "io.github.musicmanager/saf"
        const val REQUEST_TREE = 0x4D4D01
        const val REQUEST_CREATE = 0x4D4D02
    }

    private val channel = MethodChannel(
        messenger, CHANNEL, StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue()
    )
    private val resolver: ContentResolver get() = context.contentResolver
    var activity: Activity? = null
    private var pendingTree: MethodChannel.Result? = null
    private var pendingCreate: Pair<MethodChannel.Result, ByteArray>? = null

    // relPath -> docId cache per tree (directories only)
    private val dirCache = ConcurrentHashMap<String, String>()

    private class EnumSession(val tree: Uri, val exts: Set<String>) {
        val queue = LinkedBlockingQueue<List<Any>>()
        val warnings = LinkedBlockingQueue<String>()
        val done = AtomicBoolean(false)
        val cancelled = AtomicBoolean(false)
    }

    private val sessions = ConcurrentHashMap<Int, EnumSession>()
    private val nextSession = AtomicInteger(1)
    private val pool = Executors.newFixedThreadPool(2)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickTree" -> pickTree(result)
                "persistedTrees" -> result.success(resolver.persistedUriPermissions.map { it.uri.toString() })
                "releaseTree" -> {
                    val uri = Uri.parse(call.argument<String>("tree"))
                    try {
                        resolver.releasePersistableUriPermission(
                            uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                    } catch (_: SecurityException) {
                    }
                    result.success(null)
                }
                "treeAccessible" -> result.success(treeAccessible(Uri.parse(call.argument<String>("tree"))))
                "enumStart" -> result.success(enumStart(call))
                "enumNext" -> result.success(enumNext(call.argument<Int>("session")!!))
                "enumCancel" -> {
                    sessions.remove(call.argument<Int>("session"))?.cancelled?.set(true)
                    result.success(null)
                }
                "findDoc" -> result.success(findDoc(tree(call), call.argument<String>("rel")!!))
                "openFd" -> result.success(openFd(tree(call), call.argument<String>("doc")!!, call.argument<String>("mode")!!))
                "stat" -> result.success(stat(tree(call), call.argument<String>("doc")!!))
                "listNames" -> result.success(listNames(tree(call), call.argument<String>("rel")!!))
                "move" -> result.success(move(call))
                "moveAcross" -> result.success(moveAcross(call))
                "mkdirs" -> {
                    mkdirs(tree(call), call.argument<String>("rel")!!)
                    result.success(null)
                }
                "removeEmptyDir" -> {
                    removeEmptyDir(tree(call), call.argument<String>("rel")!!)
                    result.success(null)
                }
                "writeFile" -> {
                    writeFile(tree(call), call.argument<String>("rel")!!, call.argument<ByteArray>("bytes")!!,
                        call.argument<String>("mime") ?: "application/octet-stream")
                    result.success(null)
                }
                "createDocument" -> createDocument(call, result)
                "writeUri" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    resolver.openOutputStream(uri, "wt")!!.use { it.write(call.argument<ByteArray>("bytes")!!) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: FileNotFoundException) {
            result.error("not_found", e.message, null)
        } catch (e: SecurityException) {
            result.error("access_denied", e.message, null)
        } catch (e: SafError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error("saf_error", e.toString(), null)
        }
    }

    class SafError(val code: String, msg: String) : Exception(msg)

    private fun tree(call: MethodCall): Uri = Uri.parse(call.argument<String>("tree"))

    // ------------------------------------------------------------ pickers

    private fun pickTree(result: MethodChannel.Result) {
        val a = activity ?: throw SafError("no_activity", "No activity")
        pendingTree = result
        a.runOnUiThread {
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
            a.startActivityForResult(i, REQUEST_TREE)
        }
    }

    private fun createDocument(call: MethodCall, result: MethodChannel.Result) {
        val a = activity ?: throw SafError("no_activity", "No activity")
        pendingCreate = Pair(result, call.argument<ByteArray>("bytes")!!)
        a.runOnUiThread {
            val i = Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(call.argument<String>("mime") ?: "audio/x-mpegurl")
                .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
            a.startActivityForResult(i, REQUEST_CREATE)
        }
    }

    /** Called from MainActivity.onActivityResult. Returns true if handled. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQUEST_TREE -> {
                val r = pendingTree ?: return true
                pendingTree = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    r.success(null)
                    return true
                }
                pool.execute {
                    try {
                        resolver.takePersistableUriPermission(
                            uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                        val docId = DocumentsContract.getTreeDocumentId(uri)
                        val name = queryName(DocumentsContract.buildDocumentUriUsingTree(uri, docId)) ?: docId
                        r.success(mapOf("uri" to uri.toString(), "docId" to docId, "name" to name))
                    } catch (e: Exception) {
                        r.error("access_denied", e.toString(), null)
                    }
                }
                return true
            }
            REQUEST_CREATE -> {
                val (r, bytes) = pendingCreate ?: return true
                pendingCreate = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    r.success(null)
                    return true
                }
                pool.execute {
                    try {
                        resolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
                        val docId = try {
                            DocumentsContract.getDocumentId(uri)
                        } catch (_: Exception) {
                            null
                        }
                        r.success(mapOf("uri" to uri.toString(), "docId" to docId))
                    } catch (e: Exception) {
                        r.error("write_failed", e.toString(), null)
                    }
                }
                return true
            }
        }
        return false
    }

    // -------------------------------------------------------------- query

    private fun treeAccessible(tree: Uri): Boolean = try {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        resolver.query(doc, arrayOf(Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { it.moveToFirst() } ?: false
    } catch (_: Exception) {
        false
    }

    private fun queryName(doc: Uri): String? =
        resolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    private data class Child(val docId: String, val name: String, val mime: String, val size: Long, val mtime: Long)

    private fun children(tree: Uri, parentDocId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentDocId)
        val out = ArrayList<Child>()
        resolver.query(
            uri,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                out.add(Child(c.getString(0), c.getString(1) ?: "", c.getString(2) ?: "",
                    if (c.isNull(3)) 0 else c.getLong(3), if (c.isNull(4)) 0 else c.getLong(4)))
            }
        }
        return out
    }

    private fun rootDocId(tree: Uri): String = DocumentsContract.getTreeDocumentId(tree)

    private fun enumStart(call: MethodCall): Int {
        val tree = tree(call)
        val exts = call.argument<List<String>>("extensions")!!.toSet()
        val s = EnumSession(tree, exts)
        val id = nextSession.getAndIncrement()
        sessions[id] = s
        pool.execute {
            try {
                // BFS; hidden entries (leading dot) are skipped. SAF has no
                // links, so no loop detection is needed.
                val queue = ArrayDeque<Pair<String, String>>()
                queue.add(Pair(rootDocId(tree), ""))
                var batch = ArrayList<Any>()
                var last = System.currentTimeMillis()
                while (queue.isNotEmpty() && !s.cancelled.get()) {
                    val (dirId, rel) = queue.removeFirst()
                    val kids = try {
                        children(tree, dirId)
                    } catch (e: Exception) {
                        s.warnings.add("list_failed: $rel")
                        continue
                    }
                    for (k in kids) {
                        if (k.name.startsWith(".")) continue
                        val path = if (rel.isEmpty()) k.name else "$rel/${k.name}"
                        if (k.mime == Document.MIME_TYPE_DIR) {
                            dirCache["$tree|$path"] = k.docId
                            queue.add(Pair(k.docId, path))
                        } else {
                            val dot = k.name.lastIndexOf('.')
                            val ext = if (dot > 0) k.name.substring(dot + 1).lowercase() else ""
                            if (ext in s.exts) batch.add(listOf(k.docId, path, k.size, k.mtime))
                        }
                        val now = System.currentTimeMillis()
                        if (batch.size >= 300 || (batch.isNotEmpty() && now - last > 150)) {
                            s.queue.add(batch)
                            batch = ArrayList()
                            last = now
                        }
                    }
                }
                if (batch.isNotEmpty()) s.queue.add(batch)
            } catch (e: Exception) {
                s.warnings.add("enumerate_failed: $e")
            } finally {
                s.done.set(true)
            }
        }
        return id
    }

    private fun enumNext(id: Int): Map<String, Any> {
        val s = sessions[id] ?: return mapOf("entries" to emptyList<Any>(), "done" to true)
        val entries = ArrayList<Any>()
        // Wait briefly for data so that Dart does not spin.
        var first = s.queue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS)
        while (first != null) {
            entries.addAll(first)
            if (entries.size > 2000) break
            first = s.queue.poll()
        }
        val warnings = ArrayList<String>()
        s.warnings.drainTo(warnings)
        val done = s.done.get() && s.queue.isEmpty()
        if (done) sessions.remove(id)
        return mapOf("entries" to entries, "done" to done, "warnings" to warnings)
    }

    /** Document id of a relative path ("" = tree root), or null. */
    private fun findDoc(tree: Uri, rel: String): String? {
        if (rel.isEmpty()) return rootDocId(tree)
        dirCache["$tree|$rel"]?.let { return it }
        val segs = rel.split('/').filter { it.isNotEmpty() }
        var cur = rootDocId(tree)
        var path = ""
        for ((i, seg) in segs.withIndex()) {
            path = if (path.isEmpty()) seg else "$path/$seg"
            val cached = dirCache["$tree|$path"]
            if (cached != null) {
                cur = cached
                continue
            }
            val match = children(tree, cur).firstOrNull { it.name == seg } ?: return null
            cur = match.docId
            if (i < segs.size - 1 || match.mime == Document.MIME_TYPE_DIR) dirCache["$tree|$path"] = cur
        }
        return cur
    }

    private fun openFd(tree: Uri, docId: String, mode: String): Int {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
        val pfd: ParcelFileDescriptor = resolver.openFileDescriptor(uri, mode)
            ?: throw SafError("open_failed", docId)
        return pfd.detachFd()
    }

    private fun stat(tree: Uri, docId: String): List<Long>? {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
        return try {
            resolver.query(uri, arrayOf(Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED), null, null, null)?.use {
                if (it.moveToFirst()) listOf(it.getLong(0), it.getLong(1)) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun listNames(tree: Uri, rel: String): List<String> {
        val id = findDoc(tree, rel) ?: return emptyList()
        return children(tree, id).map { it.name }
    }

    // ------------------------------------------------------------ changes

    private fun mkdirs(tree: Uri, rel: String): String {
        if (rel.isEmpty()) return rootDocId(tree)
        findDoc(tree, rel)?.let { return it }
        val parentRel = rel.substringBeforeLast('/', "")
        val name = rel.substringAfterLast('/')
        val parent = mkdirs(tree, parentRel)
        val created = DocumentsContract.createDocument(
            resolver, DocumentsContract.buildDocumentUriUsingTree(tree, parent), Document.MIME_TYPE_DIR, name
        ) ?: throw SafError("mkdir_failed", rel)
        val id = DocumentsContract.getDocumentId(created)
        val actual = queryName(created)
        if (actual != name) {
            // The provider renamed the folder (conflict): undo and fail.
            DocumentsContract.deleteDocument(resolver, created)
            throw SafError("target_exists", rel)
        }
        dirCache["$tree|$rel"] = id
        return id
    }

    private fun removeEmptyDir(tree: Uri, rel: String) {
        if (rel.isEmpty()) return
        val id = findDoc(tree, rel) ?: return
        if (children(tree, id).isEmpty()) {
            DocumentsContract.deleteDocument(resolver, DocumentsContract.buildDocumentUriUsingTree(tree, id))
            dirCache.remove("$tree|$rel")
        }
    }

    private fun move(call: MethodCall): Map<String, String> {
        val tree = tree(call)
        val docId = call.argument<String>("doc")!!
        val fromDir = call.argument<String>("fromDir")!!
        val toDir = call.argument<String>("toDir")!!
        val name = call.argument<String>("name")!!
        if (listNames(tree, toDir).any { it == name }) {
            throw SafError("target_exists", "$toDir/$name")
        }
        var uri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
        if (fromDir != toDir) {
            val src = findDoc(tree, fromDir) ?: throw SafError("not_found", fromDir)
            val dst = mkdirs(tree, toDir)
            uri = try {
                DocumentsContract.moveDocument(
                    resolver, uri, DocumentsContract.buildDocumentUriUsingTree(tree, src),
                    DocumentsContract.buildDocumentUriUsingTree(tree, dst)
                ) ?: throw UnsupportedOperationException()
            } catch (e: UnsupportedOperationException) {
                copyVerifyDelete(tree, uri, tree, dst)
            } catch (e: IllegalArgumentException) {
                copyVerifyDelete(tree, uri, tree, dst)
            }
        }
        return renameTo(uri, name)
    }

    private fun moveAcross(call: MethodCall): Map<String, String> {
        val fromTree = Uri.parse(call.argument<String>("fromTree"))
        val toTree = Uri.parse(call.argument<String>("toTree"))
        val docId = call.argument<String>("doc")!!
        val toDir = call.argument<String>("toDir")!!
        val name = call.argument<String>("name")!!
        if (listNames(toTree, toDir).any { it == name }) throw SafError("target_exists", "$toDir/$name")
        val dst = mkdirs(toTree, toDir)
        val src = DocumentsContract.buildDocumentUriUsingTree(fromTree, docId)
        val moved = copyVerifyDelete(fromTree, src, toTree, dst)
        return renameTo(moved, name)
    }

    private fun renameTo(uri: Uri, name: String): Map<String, String> {
        var cur = uri
        val curName = queryName(cur)
        if (curName != name) {
            cur = DocumentsContract.renameDocument(resolver, cur, name) ?: cur
        }
        // Some providers resolve conflicts by picking another name: report
        // the name that was actually used.
        val actual = queryName(cur) ?: name
        return mapOf("doc" to DocumentsContract.getDocumentId(cur), "name" to actual)
    }

    /** Fallback when moveDocument is unsupported: copy, compare size, delete. */
    private fun copyVerifyDelete(srcTree: Uri, src: Uri, dstTree: Uri, dstDirId: String): Uri {
        val name = queryName(src) ?: throw SafError("not_found", src.toString())
        val mime = resolver.getType(src) ?: "application/octet-stream"
        val dstDir = DocumentsContract.buildDocumentUriUsingTree(dstTree, dstDirId)
        val created = DocumentsContract.createDocument(resolver, dstDir, mime, name)
            ?: throw SafError("copy_failed", name)
        var size = 0L
        resolver.openInputStream(src)!!.use { input ->
            resolver.openOutputStream(created, "w")!!.use { out -> size = input.copyTo(out) }
        }
        val srcSize = stat(srcTree, DocumentsContract.getDocumentId(src))?.get(0) ?: -1
        val dstSize = stat(dstTree, DocumentsContract.getDocumentId(created))?.get(0) ?: -2
        if (size != srcSize || dstSize != srcSize) {
            DocumentsContract.deleteDocument(resolver, created)
            throw SafError("copy_verify_failed", name)
        }
        DocumentsContract.deleteDocument(resolver, src)
        return created
    }

    private fun writeFile(tree: Uri, rel: String, bytes: ByteArray, mime: String) {
        val dirId = mkdirs(tree, rel.substringBeforeLast('/', ""))
        val name = rel.substringAfterLast('/')
        val existing = children(tree, dirId).firstOrNull { it.name == name }
        val uri = if (existing != null) {
            DocumentsContract.buildDocumentUriUsingTree(tree, existing.docId)
        } else {
            DocumentsContract.createDocument(resolver, DocumentsContract.buildDocumentUriUsingTree(tree, dirId), mime, name)
                ?: throw SafError("create_failed", rel)
        }
        if (existing == null && queryName(uri) != name) {
            DocumentsContract.deleteDocument(resolver, uri)
            throw SafError("name_changed_by_provider", rel)
        }
        resolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
    }
}
