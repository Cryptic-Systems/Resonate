/**
 * Math helpers — non-inline definitions (header provides inlines for speed).
 */
#include "utils/math_utils.h"

namespace dsp {

double db_to_linear_export(double db) { return db_to_linear(db); }
double linear_to_db_export(double lin) { return linear_to_db(lin); }
float  fast_tanh_export(float x) { return fast_tanh(x); }

} // namespace dsp
