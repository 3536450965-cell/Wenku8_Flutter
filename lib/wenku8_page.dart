import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog.dart';
import 'local_books.dart';
import 'wenku8_index.dart';
import 'wenku8_source.dart';

/// Opens the online source page from the shelf header.
Future<bool?> openWenku8Source(BuildContext context, LocalBookStore books) =>
    Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => Wenku8Page(books: books)),
    );

/// Always-visible entry for the Wenku8 source. It lives in the shelf header,
/// above whatever shelf view is showing, so the source is reachable from the
/// automatic shelf and the plain list alike.
class Wenku8EntryBar extends StatelessWidget {
  const Wenku8EntryBar({super.key, required this.books});

  final LocalBookStore books;

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
          onTap: () => openWenku8Source(context, books),
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
  _Job({required this.book, required this.volumes, required this.chapters});

  final Wenku8Book book;
  List<Wenku8Volume> volumes;
  int chapters;
  String? status;
}

class Wenku8Page extends StatefulWidget {
  const Wenku8Page({super.key, required this.books, this.onImported});

  final LocalBookStore books;
  final void Function(Novel novel)? onImported;

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

  final List<_Job> _queue = <_Job>[];
  bool _pumping = false;
  bool _cancelRequested = false;
  int _done = 0;
  int _total = 0;
  String? _runningTitle;

  @override
  void dispose() {
    _cancelRequested = true;
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
    _queue.add(_Job(book: book, volumes: picked, chapters: chapters));
    setState(() {
      _error = null;
      _hint = '已加入队列：《${book.title}》$chapters 章';
    });
    unawaited(_pump());
  }

  void _enqueueEntry(Wenku8IndexEntry entry) {
    _queue.add(
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
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        if (_cancelRequested) {
          setState(() {
            _queue.clear();
            _hint = '已取消';
          });
          break;
        }
        final job = _queue.first;
        await _run(job);
        _queue.remove(job);
        if (mounted) setState(() {});
      }
    } finally {
      _pumping = false;
      if (mounted) {
        setState(() {
          _runningTitle = null;
          _done = 0;
          _total = 0;
        });
      }
    }
  }

  Future<void> _run(_Job job) async {
    final existing = _shelf[job.book.title.toLowerCase()];
    if (existing != null) {
      final replace = await _confirmReplace(job.book.title, existing.chapters);
      if (!replace) {
        job.status = '已在书架，跳过';
        if (mounted) setState(() {});
        return;
      }
      await widget.books.remove(existing.id);
    }
    if (job.volumes.isEmpty) {
      try {
        if (mounted) {
          setState(() {
            _runningTitle = job.book.title;
            _total = 0;
            _done = 0;
          });
          job.status = '读取章节表…';
        }
        final volumes = await _client.catalog(job.book.id);
        if (volumes.isEmpty) {
          job.status = '没有可下载的章节';
          return;
        }
        job.volumes = volumes;
        job.chapters = volumes.fold<int>(
          0,
          (sum, volume) => sum + volume.chapters.length,
        );
      } catch (error) {
        job.status = '读取章节表失败：$error';
        return;
      }
    }
    if (mounted) {
      setState(() {
        _runningTitle = job.book.title;
        _done = 0;
        _total = job.chapters;
        _cancelRequested = false;
      });
    }
    try {
      final download = await _client.download(
        job.book,
        job.volumes,
        isCancelled: () => _cancelRequested,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (_cancelRequested) throw Wenku8Exception('已取消。');
      final bytes = _client.epub(download);
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/wenku8-${job.book.id}-'
        '${DateTime.now().millisecondsSinceEpoch}.epub',
      );
      await file.writeAsBytes(bytes, flush: true);
      final novel = await widget.books.importFile(job.book.fileName, file.path);
      await file.delete().catchError((_) => file);
      widget.onImported?.call(novel);
      final notes = [
        if (download.skipped.isNotEmpty) '跳过 ${download.skipped.length} 节空章节',
        if (download.failed.isNotEmpty) '${download.failed.length} 节下载失败',
      ];
      job.status = notes.isEmpty
          ? '已导入《${novel.title}》'
          : '已导入《${novel.title}》（${notes.join('，')}）';
    } catch (error) {
      job.status = '$error';
    }
  }

  Future<bool> _confirmReplace(String title, int localChapters) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('书架里已经有这本书'),
        content: Text(
          '《$title》本地已有 $localChapters 章。重新下载会替换旧书，'
          '阅读进度可能回到开头。继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('跳过'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    return result ?? false;
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
      appBar: AppBar(title: const Text('文库书源')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            '输入书名或作者就能搜到文库里的书，也可以直接填书籍编号/链接'
            '（wenku8.net/book/1234.htm 里的 1234）。下载只抓匿名可读的正文，'
            '转成 epub 放进书架。',
            style: muted,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _input,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(
              labelText: '书名 / 作者 / 编号 / 链接',
              hintText: '例如 文学少女、野村美月、1234、bdnj',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _search,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('搜索'),
              ),
              if (_pumping)
                TextButton(
                  onPressed: () {
                    _cancelRequested = true;
                    setState(() {});
                  },
                  child: const Text('取消'),
                ),
            ],
          ),
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