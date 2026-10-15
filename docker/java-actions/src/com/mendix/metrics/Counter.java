package com.mendix.metrics;

/** A metric that counts. */
public interface Counter extends Metric {
	void increment();
	void increment(double amount);
}
