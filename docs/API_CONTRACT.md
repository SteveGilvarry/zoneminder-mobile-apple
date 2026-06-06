# API Contract Notes

- Base URL: `http://zoneminder.local:8080`.
- Refresh body is `{ "token": "<refresh token>" }`.
- Refresh 60 seconds before JWT `exp`.
- Retry one 401 after refresh.
- Media URLs should prefer Bearer headers; query tokens are fallback only.
- Generated Swift code must be wrapped by `ZmApiClient` because OpenAPI `oneOf` shapes are generator-sensitive.
