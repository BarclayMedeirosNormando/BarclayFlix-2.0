import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/channel_quality.dart';
import '../../data/models/xtream_models.dart';
import '../../data/services/xtream_api_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/stream_url_builder.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/network_image_with_fallback.dart';
import '../../widgets/quality_badge.dart';
import '../../widgets/skeleton_loader.dart';
import '../../widgets/state_placeholders.dart';
import '../player/player_screen.dart';

/// [TESTE] Lista de canais de UMA categoria de Live TV já selecionada (ver
/// CategoryListScreen) — lista simples (estilo Duplecast), NÃO um grid de
/// cards: logo pequena + nome + EPG, mais compacto que o card de
/// pôster usado por Filmes/Séries (ver ContentGridScreen), o que faz
/// sentido pra Live TV: muitos canais, pouca "capa" de verdade pra mostrar
/// (a maioria só tem uma logo quadrada/circular, não um pôster).
class LiveChannelsScreen extends StatefulWidget {
  final String categoryId;
  final String categoryName;

  const LiveChannelsScreen({super.key, required this.categoryId, required this.categoryName});

  @override
  State<LiveChannelsScreen> createState() => _LiveChannelsScreenState();
}

class _LiveChannelsScreenState extends State<LiveChannelsScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFieldFocusNode = FocusNode(debugLabel: 'live_channels_search');
  bool _searching = false;
  String _query = '';
  bool _favoritesOnly = false;

  /// Protege contra double-tap (touque) ou Enter repetido rápido no D-Pad
  /// empilhando duas telas de player para o mesmo canal antes da transição
  /// completar.
  DateTime? _lastTapAt;
  static const _tapDebounce = Duration(milliseconds: 350);

  @override
  void dispose() {
    _searchController.dispose();
    _searchFieldFocusNode.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFieldFocusNode.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
  }

  void _playChannel(BuildContext context, LiveStream channel) {
    final now = DateTime.now();
    if (_lastTapAt != null && now.difference(_lastTapAt!) < _tapDebounce) return;
    _lastTapAt = now;

    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;

    final fallbackUrls = StreamUrlBuilder.buildFallbackChain(
      dns: apiService.dns,
      username: apiService.username,
      password: apiService.password,
      streamId: channel.streamId.toString(),
      contentType: StreamContentType.live,
    );

    // Live TV nunca gera progresso salvo (sem contentId aqui) -- nada a
    // recarregar ao voltar. `imageUrl` só alimenta o banner de troca de
    // canal do PlayerScreen.
    Navigator.of(context).push(fadeSlideRoute((_) => PlayerScreen(
          url: fallbackUrls.first,
          fallbackUrls: fallbackUrls,
          title: channel.name,
          imageUrl: channel.streamIcon,
        )));
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _searchController,
                  focusNode: _searchFieldFocusNode,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Buscar canal...',
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                )
              : Text(widget.categoryName),
          actions: [
            IconButton(
              icon: Icon(_searching ? Icons.close : Icons.search),
              tooltip: _searching ? 'Fechar busca' : 'Buscar',
              onPressed: () => _searching ? _closeSearch() : _openSearch(),
            ),
            IconButton(
              icon: Icon(_favoritesOnly ? Icons.favorite : Icons.favorite_border),
              tooltip: _favoritesOnly ? 'Mostrar tudo' : 'Só favoritos',
              onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
            ),
          ],
        ),
        body: Consumer2<ContentProvider, FavoritesProvider>(
          builder: (context, provider, favorites, _) {
            final state = provider.live;
            final settings = context.watch<SettingsProvider>();
            final apiService = context.read<AuthProvider>().apiService;

            if (state.streamsStatus == LoadStatus.loading && state.streams.isEmpty) {
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
                itemCount: 8,
                itemBuilder: (context, index) => const SkeletonListRow(withSubtitle: true),
              );
            }

            if (state.streamsStatus == LoadStatus.error && state.streams.isEmpty) {
              return ErrorRetry(
                message: state.streamsError ?? 'Erro ao carregar os canais.',
                onRetry: () => context.read<ContentProvider>().refresh(ContentType.live),
              );
            }

            if (state.streams.isEmpty) {
              return const EmptyHint(icon: Icons.live_tv_outlined, message: 'Nenhum canal nesta categoria.');
            }

            final query = _query.trim().toLowerCase();
            var filtered = query.isEmpty
                ? state.streams
                : state.streams.where((channel) => channel.name.toLowerCase().contains(query)).toList();
            if (_favoritesOnly) {
              filtered =
                  filtered.where((channel) => favorites.isFavorite(ContentType.live, channel.streamId.toString())).toList();
            }
            // Essencial em "Todos" (que agrega tudo numa chamada só, ver
            // ContentProvider) -- senão o cadeado da categoria não
            // protegeria nada de verdade ali.
            filtered = filtered.where((channel) => !settings.isLocked(ContentType.live, channel.categoryId)).toList();

            if (filtered.isEmpty) {
              return EmptyHint(
                icon: _favoritesOnly ? Icons.favorite_border : Icons.search_off,
                message: switch ((_favoritesOnly, query.isEmpty)) {
                  (true, true) => 'Nenhum canal favoritado ainda.',
                  (true, false) => 'Nenhum canal favoritado encontrado para "${_query.trim()}".',
                  (false, _) => 'Nenhum canal encontrado para "${_query.trim()}".',
                },
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final channel = filtered[index];
                final channelId = channel.streamId.toString();
                final isFavorite = favorites.isFavorite(ContentType.live, channelId);
                final quality = parseChannelQuality(channel.name);

                return DpadFocusHighlight(
                  key: ValueKey('live_channel_${channel.streamId}'),
                  scaleOnFocus: false,
                  borderRadius: BorderRadius.circular(4),
                  builder: (context, focusNode, hasFocus) => ListTile(
                    focusNode: focusNode,
                    autofocus: index == 0,
                    dense: true,
                    leading: _ChannelThumb(url: channel.streamIcon),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            channel.name,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.liveChannelNameStyle,
                          ),
                        ),
                        if (quality != null) ...[
                          const SizedBox(width: 6),
                          QualityBadge(quality: quality),
                        ],
                      ],
                    ),
                    subtitle: apiService == null
                        ? null
                        : _EpgSubtitle(apiService: apiService, streamId: channel.streamId),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (channel.tvArchive)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(Icons.replay_circle_filled_outlined, size: 18),
                          ),
                        GestureDetector(
                          onTap: () => context.read<FavoritesProvider>().toggleFavorite(ContentType.live, channelId),
                          child: Icon(
                            isFavorite ? Icons.favorite : Icons.favorite_border,
                            size: 18,
                            color: isFavorite ? AppTheme.primaryColor : null,
                          ),
                        ),
                      ],
                    ),
                    onTap: () => _playChannel(context, channel),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ChannelThumb extends StatelessWidget {
  final String url;

  const _ChannelThumb({required this.url});

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(color: AppTheme.surfaceColor, borderRadius: BorderRadius.circular(6)),
      child: Icon(Icons.tv, color: Colors.grey.shade500, size: _size * 0.55),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: NetworkImageWithFallback(
        url: url,
        fallback: fallback,
        width: _size,
        height: _size,
        cacheWidth: (_size * 3).round(),
        cacheHeight: (_size * 3).round(),
      ),
    );
  }
}

/// Subtítulo "Agora: X (HH:mm-HH:mm) · A seguir: Y" de um canal — busca
/// `get_short_epg` SOB DEMANDA, só quando esta linha específica é
/// construída (a `ListView.builder` só constrói o que está visível na
/// tela). Nunca bloqueia nem quebra a linha do canal: enquanto carrega ou
/// se o painel não suportar/EPG falhar, simplesmente não mostra nada.
class _EpgSubtitle extends StatefulWidget {
  final XtreamApiService apiService;
  final int streamId;

  const _EpgSubtitle({required this.apiService, required this.streamId});

  @override
  State<_EpgSubtitle> createState() => _EpgSubtitleState();
}

class _EpgSubtitleState extends State<_EpgSubtitle> {
  /// Cache em memória, por streamId, COMPARTILHADO entre todas as
  /// instâncias desta sessão -- rolar pra cima/baixo na lista não repete a
  /// chamada de rede pro mesmo canal.
  static final Map<int, List<EpgProgram>> _cache = {};

  List<EpgProgram>? _programs;

  @override
  void initState() {
    super.initState();
    final cached = _cache[widget.streamId];
    if (cached != null) {
      _programs = cached;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final programs = await widget.apiService.getShortEpg(widget.streamId.toString());
      _cache[widget.streamId] = programs;
      if (mounted) setState(() => _programs = programs);
    } catch (_) {
      // Painel sem suporte a EPG, ou erro de rede -- some silenciosamente.
    }
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final programs = _programs;
    if (programs == null || programs.isEmpty) return const SizedBox.shrink();

    final now = programs.first;
    final next = programs.length > 1 ? programs[1] : null;

    final text = StringBuffer('Agora: ${now.title}');
    if (now.start != null && now.end != null) {
      text.write(' (${_formatTime(now.start!)}-${_formatTime(now.end!)})');
    }
    if (next != null && next.title.isNotEmpty) {
      text.write(' · A seguir: ${next.title}');
    }

    return Text(
      text.toString(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
    );
  }
}
