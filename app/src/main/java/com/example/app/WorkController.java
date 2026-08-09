package com.example.app;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class WorkController {

	private static final int MAX_N = 5_000_000;

	@GetMapping("/health")
	public Map<String, String> health() {
		return Map.of("status", "UP");
	}

	// n kez ust uste SHA-256 hesaplar. Sonuc her adimda bir sonrakine girdi oldugu icin
	// derleyici islemi atlayamaz; harcanan CPU n ile dogru orantilidir.
	@GetMapping("/work")
	public Map<String, Object> work(@RequestParam(defaultValue = "50000") int n) {
		int iterations = Math.max(1, Math.min(n, MAX_N));
		long start = System.currentTimeMillis();

		byte[] data = "sre-case".getBytes();
		MessageDigest digest = sha256();
		for (int i = 0; i < iterations; i++) {
			data = digest.digest(data);
		}

		return Map.of(
				"n", iterations,
				"ms", System.currentTimeMillis() - start,
				"hash", HexFormat.of().formatHex(data));
	}

	private static MessageDigest sha256() {
		try {
			return MessageDigest.getInstance("SHA-256");
		} catch (NoSuchAlgorithmException e) {
			throw new IllegalStateException(e);
		}
	}

}
