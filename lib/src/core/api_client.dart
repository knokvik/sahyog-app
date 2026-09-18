import 'dart:convert';

import 'package:http/http.dart' as http;

typedef TokenProvider = Future<String?> Function();

class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.body});

  final int statusCode;
  final String message;
  final String? body;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.tokenProvider});

  final String baseUrl;
  final TokenProvider tokenProvider;

  Future<dynamic> get(
    String path, {
    Map<String, String>? query,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = await _headers(withAuth: withAuth);
    final response = await http.get(uri, headers: headers);
    return _decode(response);
  }

  Future<dynamic> post(
    String path, {
    Map<String, dynamic>? body,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    final response = await http.post(
      uri,
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> patch(
    String path, {
    Map<String, dynamic>? body,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    final response = await http.patch(
      uri,
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> put(
    String path, {
    Map<String, dynamic>? body,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    final response = await http.put(
      uri,
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> delete(String path, {bool withAuth = true}) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    final response = await http.delete(uri, headers: headers);
    return _decode(response);
  }

  Future<Map<String, String>> _headers({required bool withAuth}) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (withAuth) {
      final token = await tokenProvider();
      if (token == null || token.isEmpty) {
        throw ApiException(401, 'Missing auth token');
      }
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    String message = 'Request failed';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['message'] != null) {
        message = decoded['message'].toString();
      } else {
        message = response.body;
      }
    } catch (_) {
      message = response.body.isEmpty ? message : response.body;
    }

    throw ApiException(response.statusCode, message, body: response.body);
  }
}
