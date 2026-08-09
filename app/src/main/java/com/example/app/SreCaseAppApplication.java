package com.example.app;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class SreCaseAppApplication {

	public static void main(String[] args) {
		SpringApplication.run(SreCaseAppApplication.class, args);
		logJvmLimits();
	}

	// JVM'in container icinden gordugu degerler. 
	private static void logJvmLimits() {
		Runtime runtime = Runtime.getRuntime();
		System.out.printf("JVM container limits: availableProcessors=%d, maxMemory=%dMB, java=%s%n",
				runtime.availableProcessors(),
				runtime.maxMemory() / (1024 * 1024),
				System.getProperty("java.version"));
	}

}
