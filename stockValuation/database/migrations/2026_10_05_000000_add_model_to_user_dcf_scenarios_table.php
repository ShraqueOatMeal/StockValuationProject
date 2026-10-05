<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('user_dcf_scenarios', function (Blueprint $table) {
            $table->string('model', 20)->default('conservative')->after('scenario_name'); // conservative | franchise
            $table->decimal('growth_stage_2', 6, 4)->nullable()->after('growth_stage_1'); // years 6-10, franchise model only
        });
    }

    public function down(): void
    {
        Schema::table('user_dcf_scenarios', function (Blueprint $table) {
            $table->dropColumn(['model', 'growth_stage_2']);
        });
    }
};
