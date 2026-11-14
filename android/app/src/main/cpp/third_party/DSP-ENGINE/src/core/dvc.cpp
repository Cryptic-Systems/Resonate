/**
 * Direct Volume Control — translation unit so the module is always linked.
 */
#include "core/dvc.h"

namespace dsp {

float dvc_db_to_linear(float db) { return db_to_linear_f(db); }
float dvc_linear_to_db(float lin) { return linear_to_db_f(lin); }

} // namespace dsp
