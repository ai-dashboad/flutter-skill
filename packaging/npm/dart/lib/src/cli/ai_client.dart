import 'dart:convert';
import 'dart:io';

/// Lightweight AI client for explore/plan commands.
/// Supports OpenAI-compatible APIs (OpenAI, Anthropic via proxy, Ollama, etc.)
///
/// Config via environment:
///   AI_API_KEY    — API key (or OPENAI_API_KEY, ANTHROPIC_API_KEY)
///   AI_BASE_URL   — API base URL (default: https://api.openai.com/v1)
///   AI_MODEL      — Model name (default: gpt-4o-mini)
class AiClient {
  final String apiKey;
  final String baseUrl;
  final String model;

  AiClient({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  /// Create from environment variables. Returns null if no API key found.
  static AiClient? fromEnv() {
    final key = Platform.environment['AI_API_KEY'] ??
        Platform.environment['OPENAI_API_KEY'] ??
        Platform.environment['ANTHROPIC_API_KEY'];
    if (key == null || key.isEmpty) return null;

    // Detect provider from key prefix
    String baseUrl;
    String model;
    if (key.startsWith('sk-ant-')) {
      // Anthropic — use their native API
      baseUrl =
          Platform.environment['AI_BASE_URL'] ?? 'https://api.anthropic.com';
      model = Platform.environment['AI_MODEL'] ?? 'claude-3-5-haiku-20241022';
      return _AnthropicClient(apiKey: key, baseUrl: baseUrl, model: model);
    } else {
      // OpenAI-compatible (OpenAI, Ollama, OpenRouter, etc.)
      baseUrl =
          Platform.environment['AI_BASE_URL'] ?? 'https://api.openai.com/v1';
      model = Platform.environment['AI_MODEL'] ?? 'gpt-4o-mini';
    }

    return AiClient(apiKey: key, baseUrl: baseUrl, model: model);
  }

  /// Complete a prompt. Returns response text and token count.
  Future<AiResponse> complete(String prompt, {int maxTokens = 500}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl/chat/completions');
      final request = await client.postUrl(uri);
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer $apiKey');

      final body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
        'max_tokens': maxTokens,
        'temperature': 0.3,
      });
      request.write(body);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception('AI API error ${response.statusCode}: $responseBody');
      }

      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final text = data['choices']?[0]?['message']?['content'] as String? ?? '';
      final usage = data['usage'] as Map<String, dynamic>?;
      final tokens = (usage?['total_tokens'] as int?) ?? 0;

      return AiResponse(text: text, tokensUsed: tokens);
    } finally {
      client.close();
    }
  }
}

/// Anthropic native API client
class _AnthropicClient extends AiClient {
  _AnthropicClient({
    required super.apiKey,
    required super.baseUrl,
    required super.model,
  });

  @override
  Future<AiResponse> complete(String prompt, {int maxTokens = 500}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl/v1/messages');
      final request = await client.postUrl(uri);
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('x-api-key', apiKey);
      request.headers.set('anthropic-version', '2023-06-01');

      final body = jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      });
      request.write(body);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception(
            'Anthropic API error ${response.statusCode}: $responseBody');
      }

      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final content = data['content'] as List?;
      final text = content?.isNotEmpty == true
          ? (content![0]['text'] as String? ?? '')
          : '';
      final usage = data['usage'] as Map<String, dynamic>?;
      final tokens = ((usage?['input_tokens'] as int?) ?? 0) +
          ((usage?['output_tokens'] as int?) ?? 0);

      return AiResponse(text: text, tokensUsed: tokens);
    } finally {
      client.close();
    }
  }
}

class AiResponse {
  final String text;
  final int tokensUsed;

  AiResponse({required this.text, required this.tokensUsed});
}
