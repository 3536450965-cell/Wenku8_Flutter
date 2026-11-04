import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'wenku8_index.dart';
import 'wenku8_source.dart';
import 'wenku8_updates.dart';

/// Opens the online source page from the shelf header.
Future<bool?> openWenku8Source(
  BuildContext context,
  LocalBookStore books, {
  LibraryState? state,
  String? initialQuery,
}) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    builder: (_) =>
        Wenku8Page(books: books, state: state, initialQuery: initialQuery),
  ),
);

/// Always-visible entry for the Wenku8 source. It lives in the shelf header,
/// above whatever shelf view is showing, so the source is reachable from the
/// automatic shelf and the plain list alike.
class Wenku8EntryBar extends StatelessWidget {
  const Wenku8EntryBar({super.key, required this.books, this.state});

  final LocalBookStore books;
  final LibraryState? state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openWenku8Source(context, books, state: state),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Icon(CupertinoIcons.globe, size: 19, color: scheme.primary),
                const SizedBox(width: 10),
                Text(
                  '轻小说文库',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '按书名 / 编号搜书，下载到书架',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One queued download: the book, the volumes to fetch and its live status.
class _Job {
  _Job({
    required this.book,
    required this.volumes,
    required this.chapters,
    this.forceFull = false,
  });

  final Wenku8Book book;
  List<Wenku8Volume> volumes;
  int chapters;
  String? status;

  /// Ignore what is already imported and fetch every chapter again.
  final bool forceFull;
}

class Wenku8Page extends StatefulWidget {
  const Wenku8Page({
    super.key,
    required this.books,
    this.state,
    this.onImported,
    this.initialQuery,
  });

  final LocalBookStore books;
  final LibraryState? state;
  final void Function(Novel novel)? onImported;
  final String? initialQuery;

  @override
  State<Wenku8Page> createState() => _Wenku8PageState();
}

class _Wenku8PageState extends State<Wenku8Page> {
  final _input = TextEditingController();
  final _client = Wenku8Client();

  Wenku8Index? _index;
  List<Wenku8IndexEntry> _results = const [];
  String _query = '';
  Wenku8Book? _book;
  List<Wenku8Volume>? _volumes;
  final Set<int> _picked = <int>{};
  String? _error;
  String? _hint;
  bool _busy = false;

  Wenku8Downloads get _downloads => Wenku8Downloads.instance;

  List<_Job> get _queue => _downloads.queue;
  bool get _pumping => _downloads.pumping;
  int get _done => _downloads.done;
  int get _total => _downloads.total;
  String? get _runningTitle => _downloads.runningTitle;

  @override
  void initState() {
    super.initState();
    _downloads
      ..attach(widget.books, widget.state)
      ..addListener(_onDownloads);
    final initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      _input.text = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  void _onDownloads() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _downloads.removeListener(_onDownloads);
    _client.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Local books by title, so the page can mark "已在书架" and detect updates.
  Map<String, ({int id, int chapters})> get _shelf {
    final map = <String, ({int id, int chapters})>{};
    for (final novel in widget.books.books) {
      map[novel.title.toLowerCase()] = (
        id: novel.id,
        chapters: novel.chapters.length,
      );
    }
    return map;
  }

  Future<void> _search() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final direct = Wenku8Client.parseId(text);
    if (direct != null) {
      await _openBook(direct);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
      _book = null;
      _volumes = null;
      _picked.clear();
    });
    try {
      final index = _index ??= await Wenku8Index.load();
      final hits = index.search(text);
      if (!mounted) return;
      setState(() {
        _results = hits;
        _query = text;
        _hint = hits.isEmpty
            ? '索引里没有匹配「$text」的书（共 ${index.entries.length} 本）。'
                '换个关键词试试，或直接粘贴文库书籍链接。'
            : '找到 ${hits.length} 本（索引共 ${index.entries.length} 本）';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBook(String id) async {
    setState(() {
      _busy = true;
      _error = null;
      _book = null;
      _volumes = null;
      _picked.clear();
    });
    try {
      final book = await _client.book(id);
      final volumes = await _client.catalog(id);
      if (!mounted) return;
      setState(() {
        _book = book;
        _volumes = volumes;
        _picked
          ..clear()
          ..addAll(List.generate(volumes.length, (i) => i));
        _hint = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int get _pickedChapters {
    final volumes = _volumes;
    if (volumes == null) return 0;
    var total = 0;
    for (final index in _picked) {
      if (index >= 0 && index < volumes.length) {
        total += volumes[index].chapters.length;
      }
    }
    return total;
  }

  void _enqueueCurrent() {
    final book = _book;
    final volumes = _volumes;
    if (book == null || volumes == null) return;
    final picked = [
      for (var i = 0; i < volumes.length; i++)
        if (_picked.contains(i)) volumes[i],
    ];
    if (picked.isEmpty) {
      setState(() => _error = '先选中至少一卷。');
      return;
    }
    final chapters = picked.fold<int>(
      0,
      (sum, volume) => sum + volume.chapters.length,
    );
    _downloads.enqueue(
      _Job(book: book, volumes: picked, chapters: chapters),
    );
    setState(() {
      _error = null;
      _hint = '已加入队列：《${book.title}》$chapters 章';
    });
  }

  void _enqueueBook(Wenku8Book book, {bool forceFull = false}) {
    _downloads.enqueue(
      _Job(
        book: book,
        volumes: const [],
        chapters: 0,
        forceFull: forceFull,
      ),
    );
    setState(() {
      _error = null;
      _hint = forceFull
          ? '已加入队列（重下）：《${book.title}》'
          : '已加入队列：《${book.title}》';
    });
  }

  void _enqueueEntry(
    Wenku8IndexEntry entry, {
    bool forceFull = false,
    bool incremental = false,
  }) {
    if (incremental || forceFull) {
      _enqueueBook(
        Wenku8Book(
          id: '${entry.id}',
          title: entry.title,
          author: entry.author,
          category: entry.category,
          status: entry.status,
          length: entry.lengthLabel,
          updated: '',
          summary: '',
          coverUrl: null,
        ),
        forceFull: forceFull,
      );
      return;
    }
    _downloads.enqueue(
      _Job(
        book: Wenku8Book(
          id: '${entry.id}',
          title: entry.title,
          author: entry.author,
          category: entry.category,
          status: entry.status,
          length: entry.lengthLabel,
          updated: '',
          summary: '',
          coverUrl: null,
        ),
        volumes: const [],
        chapters: 0,
      ),
    );
    setState(() => _hint = '已加入队列：《${entry.title}》');
  }


  Future<void> _showEntryActions(Wenku8IndexEntry entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.title),
              subtitle: Text(
                [
                  if (entry.author.isNotEmpty) entry.author,
                  if (entry.category.isNotEmpty) entry.category,
                  if (entry.length > 0) entry.lengthLabel,
                ].join(' · '),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载并导入'),
              onTap: () => Navigator.of(context).pop('download'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('加入下载队列'),
              onTap: () => Navigator.of(context).pop('queue'),
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('更新已下载的书（只补新章）'),
              onTap: () => Navigator.of(context).pop('update'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('强制重新下载整本'),
              onTap: () => Navigator.of(context).pop('redownload'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'update') {
      _enqueueEntry(entry, incremental: true);
      return;
    }
    if (action == 'redownload') {
      _enqueueEntry(entry, forceFull: true);
      return;
    }
    _enqueueEntry(entry);
    if (action == 'download' && !_pumping) {
      _input.text = '${entry.id}';
      await _openBook('${entry.id}');
    }
  }

  Future<void> _refreshIndex() async {
    setState(() => _busy = true);
    try {
      final index = await Wenku8Index.forceRefresh();
      if (!mounted) return;
      setState(() {
        _index = index;
        _busy = false;
        _hint = '书目索引已更新，共 ${index.entries.length} 本。';
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '刷新索引失败：$error';
      });
    }
  }

  Future<void> _cleanTemporaryFiles() async {
    var removed = 0;
    try {
      final directory = await getTemporaryDirectory();
      await for (final entity in directory.list()) {
        final name = entity.path.split(RegExp(r'[\\/]')).last;
        if (entity is File && (name.endsWith('.epub') || name.startsWith('wenku8-'))) {
          await entity.delete();
          removed++;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _hint = '已清理 $removed 个下载临时文件。');
  }

  Widget _brandHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canPop = Navigator.of(context).canPop();
    return Row(
      children: [
        if (canPop)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).maybePop(),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    CupertinoIcons.back,
                    size: 21,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 46,
            height: 46,
            color: scheme.inverseSurface,
            child: Image.asset(
              'assets/branding/app-icon.png',
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                CupertinoIcons.book_solid,
                size: 22,
                color: scheme.onInverseSurface,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '轻小说文库',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'WENKU8 / READING ARCHIVE',
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10.5,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _RoundAction(
          icon: CupertinoIcons.search,
          label: '搜索文库',
          onPressed: _openSearchSheet,
        ),
      ],
    );
  }

  Widget _searchBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: TextField(
        controller: _input,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          hintText: '书名 / 作者 / 编号 / 链接',
          isDense: true,
          prefixIcon: const Icon(CupertinoIcons.search, size: 18),
          suffixIcon: IconButton(
            tooltip: '搜索',
            icon: const Icon(CupertinoIcons.arrow_right_circle_fill, size: 20),
            onPressed: _search,
          ),
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Future<void> _checkShelfUpdates() async {
    final watcher = Wenku8Updates.instance;
    if (watcher == null) {
      _say('书架还没准备好，回书架页面再试一次。');
      return;
    }
    await watcher.check(force: true);
    if (!mounted) return;
    final failures = watcher.error;
    if (failures != null) {
      _say('检查没成功：$failures');
      return;
    }
    final noticed = watcher.notices;
    _say(
      noticed.isEmpty
          ? '全部是最新的。'
          : '有 ${noticed.length} 本可以更新，回书架顶部点提示即可更新。',
    );
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSearchSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: MediaQuery.viewInsetsOf(sheet).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _input,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                Navigator.of(sheet).pop();
                _search();
              },
              decoration: const InputDecoration(
                labelText: '书名 / 作者 / 编号 / 链接',
                hintText: '例如 文学少女、野村美月、1234、bdnj',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(sheet).pop();
                _search();
              },
              icon: const Icon(Icons.search, size: 18),
              label: const Text('搜索'),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    _refreshIndex();
                  },
                  child: const Text('刷新书目索引'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    _cleanTemporaryFiles();
                  },
                  child: const Text('清理下载缓存'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    _checkShelfUpdates();
                  },
                  child: const Text('检查书架更新'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.7);
    final book = _book;
    final volumes = _volumes;
    final shelf = _shelf;
    final chapters = volumes == null
        ? 0
        : volumes.fold<int>(0, (sum, volume) => sum + volume.chapters.length);
    final busy = _busy || _pumping;

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQuery.paddingOf(context).top + 6,
          20,
          32,
        ),
        children: [
          _brandHeader(context),
          _searchBar(context),
          if (_busy && !_pumping)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
          if (_pumping) ...[
            const SizedBox(height: 16),
            if (_total > 0)
              LinearProgressIndicator(value: _done / _total)
            else
              const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(
              _total > 0
                  ? '正在下载《${_runningTitle ?? ''}》$_done / $_total 章'
                  : '正在准备《${_runningTitle ?? ''}》…',
              style: muted,
            ),
            if (_queue.length > 1) Text('队列里还有 ${_queue.length - 1} 本', style: muted),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  _downloads.cancel();
                  setState(() {});
                },
                child: const Text('取消下载'),
              ),
            ),
          ],
          if (_queue.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final job in _queue)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '· ${job.book.title}'
                  '${job.status == null ? '' : ' — ${job.status}'}',
                  style: muted,
                ),
              ),
          ],
          if (_downloads.failedBooks.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final item in _downloads.failedBooks.values)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '《${item.book.title}》有 ${item.count} 节没下下来',
                      style: muted,
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _enqueueBook(item.book),
                    child: const Text('补下'),
                  ),
                ],
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: scheme.error, height: 1.7)),
          ],
          if (_hint != null) ...[
            const SizedBox(height: 16),
            Text(_hint!, style: muted),
          ],
          if (_queue.isEmpty && _results.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('搜索「$_query」的结果', style: muted),
          ],
          for (final entry in _results)
            Builder(
              builder: (context) {
                final local = shelf[entry.title.toLowerCase()];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.title),
                  subtitle: Text(
                    [
                      if (entry.author.isNotEmpty) entry.author,
                      if (entry.category.isNotEmpty) entry.category,
                      if (entry.length > 0) entry.lengthLabel,
                      if (entry.status.isNotEmpty) entry.status,
                      if (local != null) '已在书架 ${local.chapters} 章',
                    ].join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '加入下载队列',
                        icon: const Icon(Icons.playlist_add, size: 20),
                        onPressed: busy ? null : () => _enqueueEntry(entry),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  onTap: busy
                      ? null
                      : () {
                          _input.text = '${entry.id}';
                          _openBook('${entry.id}');
                        },
                  onLongPress: busy
                      ? null
                      : () => _showEntryActions(entry),
                );
              },
            ),
          if (book != null) ...[
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Wenku8Cover(url: book.coverUrl, width: 84),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(book.title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Text(
                        [
                          if (book.author.isNotEmpty) book.author,
                          if (book.category.isNotEmpty) book.category,
                          if (book.status.isNotEmpty) book.status,
                          if (book.length.isNotEmpty) book.length,
                        ].join(' · '),
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (book.summary.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(book.summary, style: muted),
            ],
            if (volumes != null && shelf[book.title.toLowerCase()] != null) ...[
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final local = shelf[book.title.toLowerCase()]!;
                  final latest = local.chapters == chapters;
                  return Row(
                    children: [
                      Icon(
                        latest ? Icons.check_circle_outline : Icons.sync,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          latest
                              ? '书架里已有这本书（${local.chapters} 章，已是最新）'
                              : '书架里已有 ${local.chapters} 章，在线 $chapters 章，可以更新',
                          style: muted,
                        ),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _enqueueBook(book, forceFull: false),
                        child: const Text('检查更新'),
                      ),
                    ],
                  );
                },
              ),
            ],
            if (volumes != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('共 ${volumes.length} 卷 $chapters 章', style: muted),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_picked.length == volumes.length) {
                        _picked.clear();
                      } else {
                        _picked
                          ..clear()
                          ..addAll(List.generate(volumes.length, (i) => i));
                      }
                    }),
                    child: Text(
                      _picked.length == volumes.length ? '全不选' : '全选',
                    ),
                  ),
                ],
              ),
              for (var i = 0; i < volumes.length; i++)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _picked.contains(i),
                  title: Text(
                    volumes[i].title.isEmpty
                        ? '第 ${i + 1} 卷'
                        : volumes[i].title,
                  ),
                  subtitle: Text('${volumes[i].chapters.length} 章'),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _picked.add(i);
                    } else {
                      _picked.remove(i);
                    }
                  }),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _picked.isEmpty ? null : _enqueueCurrent,
                icon: const Icon(Icons.download, size: 18),
                label: Text('加入队列（$_pickedChapters 章）'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: scheme.surface,
        elevation: 2.5,
        shadowColor: scheme.shadow.withValues(alpha: 0.28),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, size: 22, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _Wenku8Cover extends StatelessWidget {
  const _Wenku8Cover({required this.url, required this.width});

  final String? url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: width * 1.4,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        CupertinoIcons.book,
        size: width * 0.4,
        color: scheme.onSurfaceVariant,
      ),
    );
    final src = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: src == null
          ? placeholder
          : Image.network(
              src,
              width: width,
              height: width * 1.4,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : placeholder,
            ),
    );
  }
}


/// The download queue lives here rather than in the page, so a download keeps
/// running while the reader moves on to other books.
class Wenku8Downloads extends ChangeNotifier {
  Wenku8Downloads._();

  static final Wenku8Downloads instance = Wenku8Downloads._();

  final Wenku8Client _client = Wenku8Client();
  final List<_Job> queue = <_Job>[];

  /// Books whose last import had chapters the site refused to hand over, so the
  /// page can offer a one-tap retry instead of silently shipping a short book.
  final Map<String, ({Wenku8Book book, int count})> failedBooks = {};

  LocalBookStore? books;
  LibraryState? state;

  bool pumping = false;
  bool cancelRequested = false;
  int done = 0;
  int total = 0;
  String? runningTitle;

  void attach(LocalBookStore store, LibraryState? libraryState) {
    books = store;
    state = libraryState;
  }

  void enqueue(_Job job) {
    queue.add(job);
    notifyListeners();
    unawaited(_pump());
  }

  void cancel() {
    cancelRequested = true;
    notifyListeners();
  }

  Future<void> _pump() async {
    if (pumping) return;
    pumping = true;
    notifyListeners();
    try {
      while (queue.isNotEmpty) {
        if (cancelRequested) {
          queue.clear();
          break;
        }
        final job = queue.first;
        await _run(job);
        queue.remove(job);
        notifyListeners();
      }
    } finally {
      pumping = false;
      runningTitle = null;
      done = 0;
      total = 0;
      cancelRequested = false;
      notifyListeners();
    }
  }

  Novel? _localFor(LocalBookStore store, String title) {
    final wanted = title.trim().toLowerCase();
    for (final novel in store.books) {
      if (novel.title.trim().toLowerCase() == wanted) return novel;
    }
    for (final novel in store.books) {
      if (novel.title.trim().toLowerCase().startsWith(wanted)) return novel;
    }
    return null;
  }

  Future<List<Wenku8Volume>> _loadCatalog(
    _Job job,
    List<Wenku8Volume> known,
  ) async {
    if (known.isNotEmpty) return known;
    job.status = '读取章节表…';
    notifyListeners();
    try {
      final volumes = await _client.catalog(job.book.id);
      if (volumes.isEmpty) {
        job.status = '没有可下载的章节';
        notifyListeners();
        return const [];
      }
      job.volumes = volumes;
      job.chapters = volumes.fold<int>(
        0,
        (sum, volume) => sum + volume.chapters.length,
      );
      notifyListeners();
      return volumes;
    } catch (error) {
      job.status = '读取章节表失败：$error';
      notifyListeners();
      return const [];
    }
  }

  /// Matches imported chapters against the fresh catalog by title, so an update
  /// only fetches what is new instead of the whole book again.
  Future<({Map<String, String> bodies, List<Wenku8Volume> missing, int reused})>
  _planIncremental(
    LocalBookStore store,
    Novel local,
    List<Wenku8Volume> catalog,
  ) async {
    final flat = [for (final volume in catalog) ...volume.chapters];
    final bodies = <String, String>{};
    var cursor = 0;
    var reused = 0;
    for (final chapter in local.chapters) {
      final wanted = chapter.title.trim();
      var found = -1;
      for (var i = cursor; i < flat.length; i++) {
        if (flat[i].title.trim() == wanted) {
          found = i;
          break;
        }
      }
      if (found < 0) continue;
      final text = await store.chapterContent(local.id, chapter);
      if (text.trim().isEmpty) continue;
      bodies[flat[found].id] = text;
      cursor = found + 1;
      reused++;
    }
    final missing = <Wenku8Volume>[];
    for (final volume in catalog) {
      final copy = Wenku8Volume(volume.title);
      for (final chapter in volume.chapters) {
        if (!bodies.containsKey(chapter.id)) copy.chapters.add(chapter);
      }
      if (copy.chapters.isNotEmpty) missing.add(copy);
    }
    return (bodies: bodies, missing: missing, reused: reused);
  }

  List<Wenku8Volume> _mergeVolumes(
    List<Wenku8Volume> catalog,
    Map<String, String> bodies,
  ) {
    final merged = <Wenku8Volume>[];
    for (final volume in catalog) {
      final copy = Wenku8Volume(volume.title);
      for (final chapter in volume.chapters) {
        if (bodies.containsKey(chapter.id)) copy.chapters.add(chapter);
      }
      if (copy.chapters.isNotEmpty) merged.add(copy);
    }
    return merged;
  }

  Future<void> _run(_Job job) async {
    final store = books;
    if (store == null) return;
    final local = job.forceFull ? null : _localFor(store, job.book.title);
    var reused = const <String, String>{};
    var reusedCount = 0;

    var catalog = await _loadCatalog(job, job.volumes);
    if (catalog.isEmpty) return;

    if (local != null) {
      final plan = await _planIncremental(store, local, catalog);
      reused = plan.bodies;
      reusedCount = plan.reused;
      if (plan.missing.isEmpty && reusedCount > 0) {
        job.status = '已是最新（$reusedCount 章）';
        notifyListeners();
        return;
      }
      job.volumes = plan.missing.isEmpty ? catalog : plan.missing;
      job.chapters = job.volumes.fold<int>(
        0,
        (sum, volume) => sum + volume.chapters.length,
      );
    }

    runningTitle = job.book.title;
    done = 0;
    total = job.chapters;
    cancelRequested = false;
    notifyListeners();
    try {
      final download = await _client.download(
        job.book,
        job.volumes,
        isCancelled: () => cancelRequested,
        onProgress: (value, maximum) {
          done = value;
          total = maximum;
          notifyListeners();
        },
      );
      if (cancelRequested) throw Wenku8Exception('已取消。');
      final bodies = <String, String>{...reused, ...download.chapters};
      final merged = Wenku8Download(
        job.book,
        _mergeVolumes(catalog, bodies),
        bodies,
        images: download.images,
        skipped: download.skipped,
        failed: download.failed,
        cover: download.cover,
      );
      final bytes = _client.epub(merged);
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/wenku8-${job.book.id}-'
        '${DateTime.now().millisecondsSinceEpoch}.epub',
      );
      await file.writeAsBytes(bytes, flush: true);
      final position = local == null ? null : state?.positionFor(local.id);
      if (local != null) await store.remove(local.id);
      final novel = await store.importFile(job.book.fileName, file.path);
      await file.delete().catchError((_) => file);
      if (position != null) {
        await state?.savePosition(
          novel: novel,
          chapter: position.chapter.clamp(0, novel.chapters.length - 1),
          offset: position.offset,
          maximum: position.offset.abs() + 1,
          width: position.width,
          paragraphIndex: position.paragraphIndex,
          paragraphFraction: position.paragraphFraction,
          textOffset: position.textOffset,
          textScale: position.textScale,
          typeface: position.typeface,
        );
      }
      final notes = [
        if (reusedCount > 0) '复用 $reusedCount 章',
        if (download.chapters.length > 0) '新增 ${download.chapters.length} 章',
        if (download.skipped.isNotEmpty) '跳过 ${download.skipped.length} 节空章节',
        if (download.failed.isNotEmpty) '${download.failed.length} 节下载失败',
      ];
      if (download.failed.isEmpty) {
        failedBooks.remove(job.book.id);
      } else {
        failedBooks[job.book.id] = (
          book: job.book,
          count: download.failed.length,
        );
      }
      job.status = notes.isEmpty
          ? '已导入《${novel.title}》'
          : '已导入《${novel.title}》（${notes.join('，')}）';
      notifyListeners();
    } catch (error) {
      job.status = '$error';
      notifyListeners();
    }
  }
}
