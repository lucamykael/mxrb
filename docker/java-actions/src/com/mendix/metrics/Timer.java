package com.mendix.metrics;

import java.util.concurrent.TimeUnit;
import java.util.function.Supplier;

/** A metric that times. */
public interface Timer extends Metric {
	void record(long amount, TimeUnit unit);
	<T> T record(Supplier<T> work);
}
