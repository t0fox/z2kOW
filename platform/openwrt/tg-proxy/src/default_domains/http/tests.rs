use std::time::Duration;

use tokio::io::AsyncWriteExt;

use super::*;

#[test]
fn content_length_rejects_conflicting_duplicates() {
    let mut headers = [
        httparse::Header {
            name: "Content-Length",
            value: b"10",
        },
        httparse::Header {
            name: "Content-Length",
            value: b"999",
        },
    ];

    let err = content_length(&headers).unwrap_err();

    assert!(err.contains("conflicting"));
    headers[1].value = b"10";
    assert_eq!(content_length(&headers).unwrap(), Some(10));
}

#[tokio::test]
async fn read_http_response_body_rejects_conflicting_content_length_with_chunked() {
    let mut response =
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n0\r\n\r\n"
            .as_slice();

    let err = read_http_response_body(&mut response).await.unwrap_err();

    assert!(err.contains("conflicting"));
}

#[tokio::test]
async fn read_http_response_body_stops_at_content_length_without_eof() {
    let (mut client, mut server) = tokio::io::duplex(1024);
    let writer = tokio::spawn(async move {
        server
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nvirkgj.com\nextra")
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_secs(5)).await;
    });

    let body = read_http_response_body(&mut client).await.unwrap();

    assert_eq!(body, "virkgj.com\n");
    writer.abort();
    assert!(writer.await.unwrap_err().is_cancelled());
}

#[tokio::test]
async fn read_http_response_body_accepts_chunked_body() {
    let mut response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nvirkgj\r\n5\r\n.com\n\r\n0\r\n\r\n".as_slice();

    let body = read_http_response_body(&mut response).await.unwrap();

    assert_eq!(body, "virkgj.com\n");
}

#[tokio::test]
async fn read_http_response_body_rejects_truncated_chunked_terminator() {
    let mut response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n".as_slice();

    let err = read_http_response_body(&mut response).await.unwrap_err();

    assert!(err.contains("unexpected EOF"));
}

#[tokio::test]
async fn read_http_response_body_accepts_more_than_32_headers() {
    let mut response = b"HTTP/1.1 200 OK\r\n".to_vec();
    for i in 0..40 {
        response.extend_from_slice(format!("X-Test-{i}: value\r\n").as_bytes());
    }
    response.extend_from_slice(b"Content-Length: 11\r\n\r\nvirkgj.com\n");

    let body = read_http_response_body(&mut response.as_slice())
        .await
        .unwrap();

    assert_eq!(body, "virkgj.com\n");
}

#[tokio::test]
async fn read_http_response_body_rejects_non_200_status() {
    let mut response = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".as_slice();

    let err = read_http_response_body(&mut response).await.unwrap_err();

    assert!(err.contains("HTTP status 404"));
}

#[tokio::test]
async fn read_http_response_body_rejects_oversized_content_length() {
    let mut response = b"HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n".as_slice();

    let err = read_http_response_body(&mut response).await.unwrap_err();

    assert!(err.contains("exceeds limit"));
}

#[tokio::test]
async fn read_http_response_body_accepts_eof_delimited_body_at_limit() {
    let mut response = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
    response.extend(vec![b'a'; MAX_BODY_BYTES]);

    let body = read_http_response_body(&mut response.as_slice())
        .await
        .unwrap();

    assert_eq!(body.len(), MAX_BODY_BYTES);
}
